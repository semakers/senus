// El puente Bluetooth de SENUS en Windows. Ver puente_bluetooth.h. Es la traducción
// de macos/Runner/PuenteBluetooth.swift: mismas órdenes, mismos avisos, mismas
// pausas y plazos (vigilar cada 3 s, una llamada caduca a los 15 s, emparejar cada
// 4 s). [sin probar en silicio al escribirlo]

// winsock2 antes que cualquier <windows.h>: si no, entra winsock.h y chocan.
#include <winsock2.h>
#include <ws2bth.h>
#include <bluetoothapis.h>

#include "puente_bluetooth.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <functional>
#include <iterator>
#include <map>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <vector>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Reloj = std::chrono::steady_clock;
using namespace std::chrono_literals;

namespace {

constexpr auto kPausaVigilar = 3s;   // cada cuánto se llama a quien no tiene canal
constexpr auto kPlazoIntento = 15s;  // cuánto se espera una llamada
constexpr auto kPausaPar = 4s;       // cada cuánto se reintenta emparejar
constexpr int kFalloPlazo = -1;      // códigos propios de anotarFallo, como los IOReturn de la Mac
constexpr int kFalloSinEmparejar = -2;

// Serial Port, 0x1101 sobre la base de Bluetooth. Propio para no depender de dónde
// se defina SerialPortServiceClass_UUID.
const GUID kSerialPort = {0x00001101, 0x0000, 0x1000, {0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB}};

// «AA:BB:CC:DD:EE:FF», el byte más alto primero, como lo dice el teléfono.
std::string Texto(BTH_ADDR a) {
  char t[18];
  std::snprintf(t, sizeof t, "%02X:%02X:%02X:%02X:%02X:%02X",
                static_cast<unsigned>((a >> 40) & 0xFF), static_cast<unsigned>((a >> 32) & 0xFF),
                static_cast<unsigned>((a >> 24) & 0xFF), static_cast<unsigned>((a >> 16) & 0xFF),
                static_cast<unsigned>((a >> 8) & 0xFF), static_cast<unsigned>(a & 0xFF));
  return t;
}

// «aa-bb-…» o «aa:bb:…» → «AA:BB:…».
std::string Normalizar(std::string d) {
  for (auto& c : d) {
    c = c == '-' ? ':' : static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
  }
  return d;
}

bool Leer(const std::string& entrada, BTH_ADDR* a) {
  const std::string d = Normalizar(entrada);
  if (d.size() != 17) return false;
  BTH_ADDR v = 0;
  for (size_t i = 0; i < 17; i++) {
    if (i % 3 == 2) {
      if (d[i] != ':') return false;
      continue;
    }
    const char c = d[i];
    int n;
    if (c >= '0' && c <= '9') n = c - '0';
    else if (c >= 'A' && c <= 'F') n = c - 'A' + 10;
    else return false;
    v = (v << 4) | static_cast<BTH_ADDR>(n);
  }
  *a = v;
  return true;
}

// La cola hacia el hilo de la ventana. Los hilos de trabajo la comparten: muerta la
// ventana (viva = false), lo que dejen se tira.
struct Cola {
  std::mutex m;
  std::deque<std::function<void()>> q;
  HWND ventana;
  std::atomic<bool> viva{true};

  void Poner(std::function<void()> f) {
    if (!viva) return;
    {
      std::lock_guard<std::mutex> g(m);
      q.push_back(std::move(f));
    }
    PostMessage(ventana, PuenteBluetooth::kMensaje, 0, 0);
  }

  std::deque<std::function<void()>> Sacar() {
    std::lock_guard<std::mutex> g(m);
    std::deque<std::function<void()>> l;
    l.swap(q);
    return l;
  }
};

// El socket de una llamada: se cierra UNA vez, lo cierre quien lo cierre.
void Soltar(std::atomic<SOCKET>& s) {
  const SOCKET x = s.exchange(INVALID_SOCKET);
  if (x != INVALID_SOCKET) closesocket(x);
}

const EncodableValue* Arg(const EncodableMap* m, const char* k) {
  if (!m) return nullptr;
  auto it = m->find(EncodableValue(std::string(k)));
  return it == m->end() ? nullptr : &it->second;
}

std::string ArgTexto(const EncodableMap* m, const char* k, const std::string& defecto = "") {
  const auto* v = Arg(m, k);
  if (v) {
    if (const auto* s = std::get_if<std::string>(v)) return *s;
  }
  return defecto;
}

int64_t ArgEntero(const EncodableMap* m, const char* k, int64_t defecto) {
  const auto* v = Arg(m, k);
  if (v) {
    if (const auto* i = std::get_if<int32_t>(v)) return *i;
    if (const auto* l = std::get_if<int64_t>(v)) return *l;
  }
  return defecto;
}

// Lo que el callback del PIN necesita, vivo mientras esté registrado (y algo más:
// Windows no dice si un callback sigue corriendo tras darlo de baja).
struct Autentica {
  std::shared_ptr<Cola> cola;
  std::function<void(DWORD)> alContestar;  // corre en la cola: el aviso «pin»
  BTH_ADDR direccion;
  std::string pin;
};

BOOL CALLBACK Contestar(LPVOID contexto, PBLUETOOTH_AUTHENTICATION_CALLBACK_PARAMS p) {
  auto* a = static_cast<Autentica*>(contexto);
  if (!a || !p || p->deviceInfo.Address.ullLong != a->direccion) return FALSE;
  BLUETOOTH_AUTHENTICATE_RESPONSE r = {};
  r.bthAddressRemote = p->deviceInfo.Address;
  r.authMethod = p->authenticationMethod;
  r.negativeResponse = FALSE;
  if (p->authenticationMethod == BLUETOOTH_AUTHENTICATION_METHOD_LEGACY) {
    // El W580 (STLC2500, Bluetooth 2.0) solo sabe del PIN de siempre.
    const size_t n = a->pin.size() < BTH_MAX_PIN_SIZE ? a->pin.size() : BTH_MAX_PIN_SIZE;
    for (size_t i = 0; i < n; i++) r.pinInfo.pin[i] = static_cast<UCHAR>(a->pin[i]);
    r.pinInfo.pinLength = static_cast<UCHAR>(n);
  } else if (p->authenticationMethod == BLUETOOTH_AUTHENTICATION_METHOD_NUMERIC_COMPARISON) {
    r.numericCompInfo.NumericValue = p->Numeric_Value;
  } else if (p->authenticationMethod == BLUETOOTH_AUTHENTICATION_METHOD_PASSKEY_NOTIFICATION) {
    r.passkeyInfo.passkey = p->Passkey;
  }
  const DWORD e = BluetoothSendAuthenticationResponseEx(nullptr, &r);
  auto aviso = a->alContestar;
  a->cola->Poner([aviso, e] { aviso(e); });
  return TRUE;
}

}  // namespace

class PuenteBluetoothImpl {
 public:
  PuenteBluetoothImpl(flutter::BinaryMessenger* mensajero, HWND ventana);
  ~PuenteBluetoothImpl();

  void Drenar() {
    for (auto& f : cola_->Sacar()) f();
  }
  void Apagar();

 private:
  using Resultado = flutter::MethodResult<EncodableValue>;

  struct Escritura {
    std::vector<uint8_t> datos;
    std::function<void(int)> alAcabar;  // corre en la cola
  };

  struct Conexion {
    int id = 0;
    SOCKET s = INVALID_SOCKET;
    BTH_ADDR direccion = 0;
    std::string texto;
    std::mutex m;
    std::condition_variable cv;
    std::deque<Escritura> cola;
    bool cerrar = false;
  };

  struct Intento {
    Reloj::time_point desde = Reloj::now();
    std::atomic<SOCKET> s{INVALID_SOCKET};
  };

  struct Armado {
    BTH_ADDR direccion;
    std::string texto;
    std::string pin;
  };

  void Atender(const flutter::MethodCall<EncodableValue>& llamada, std::unique_ptr<Resultado> r);
  void Avisar(EncodableMap m) {
    if (sumidero_) sumidero_->Success(EncodableValue(std::move(m)));
  }
  void Registro(const std::string& t) {
    Avisar({{EncodableValue("e"), EncodableValue("registro")}, {EncodableValue("texto"), EncodableValue(t)}});
  }
  void AvisarPar(const std::string& dir, const char* estado, int64_t codigo) {
    Avisar({{EncodableValue("e"), EncodableValue("emparejamiento")},
            {EncodableValue("direccion"), EncodableValue(dir)},
            {EncodableValue("estado"), EncodableValue(estado)},
            {EncodableValue("codigo"), EncodableValue(codigo)}});
  }

  bool AbrirRadio();
  bool Emparejado(BTH_ADDR a);
  EncodableMap Consultar();
  std::optional<std::string> Encender(const std::string& nombre, int preferido, int* canal);
  void Aceptar(SOCKET escucha);
  void ArrancarReloj();
  void PararReloj();
  void Tic();

  std::optional<std::string> Vigilar(const EncodableList* direcciones, int64_t canal);
  void VueltaVigilar();
  void Llamar(const std::string& dir, BTH_ADDR a);
  void FinLlamada(const std::string& dir, std::shared_ptr<Intento> i, int error);
  void PararVigilancia();
  void AnotarFallo(const std::string& dir, int codigo);

  void Alta(SOCKET s, BTH_ADDR a);
  void Escribir(int id, std::vector<uint8_t> datos, std::shared_ptr<Resultado> r);
  void Cerrado(int id);

  std::optional<std::string> Armar(const std::string& dir, const std::string& pin);
  void Desarmar();
  void VigilarPar();
  void ArrancarPar();

  std::shared_ptr<Cola> cola_ = std::make_shared<Cola>();
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> ordenes_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> eventos_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sumidero_;
  bool wsa_ = false;

  HANDLE radio_ = nullptr;
  BTH_ADDR local_ = 0;

  // El servidor.
  SOCKET escucha_ = INVALID_SOCKET;
  int canal_ = 0;
  SOCKADDR_BTH sdp_direccion_ = {};
  CSADDR_INFO sdp_csa_ = {};
  std::wstring sdp_nombre_;
  WSAQUERYSETW sdp_ = {};
  bool sdp_hecho_ = false;

  std::map<int, std::shared_ptr<Conexion>> conexiones_;
  int sig_id_ = 1;

  // A quién se llama, y por qué canal suyo.
  std::vector<std::string> vigiladas_;
  int canal_telefono_ = 0;
  std::map<std::string, std::shared_ptr<Intento>> intentos_;
  std::map<std::string, int> ultimo_fallo_;
  Reloj::time_point ultima_vuelta_{};  // el origen del reloj: la primera vuelta no espera

  // El reloj: un tic por segundo a la cola mientras haya algo que vigilar.
  std::thread reloj_;
  std::mutex reloj_m_;
  std::condition_variable reloj_cv_;
  bool reloj_parar_ = false;

  // Emparejar.
  std::optional<Armado> armado_;
  HBLUETOOTH_AUTHENTICATION_REGISTRATION registro_auth_ = nullptr;
  std::vector<std::shared_ptr<Autentica>> autenticas_;  // no se liberan hasta el final
  bool par_en_curso_ = false;
  bool par_listo_ = false;
  Reloj::time_point par_desde_{};
  int gen_par_ = 0;
};

PuenteBluetoothImpl::PuenteBluetoothImpl(flutter::BinaryMessenger* mensajero, HWND ventana) {
  cola_->ventana = ventana;
  WSADATA w;
  wsa_ = WSAStartup(MAKEWORD(2, 2), &w) == 0;
  const auto& codec = flutter::StandardMethodCodec::GetInstance();
  ordenes_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(mensajero, "senus/puente_bt", &codec);
  ordenes_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& llamada, std::unique_ptr<Resultado> r) {
        Atender(llamada, std::move(r));
      });
  eventos_ = std::make_unique<flutter::EventChannel<EncodableValue>>(mensajero, "senus/puente_bt/eventos", &codec);
  eventos_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
      [this](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& s)
          -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        sumidero_ = std::move(s);
        return nullptr;
      },
      [this](const EncodableValue*) -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
        sumidero_.reset();
        return nullptr;
      }));
}

PuenteBluetoothImpl::~PuenteBluetoothImpl() {
  Apagar();
  cola_->viva = false;
  PararReloj();
  sumidero_.reset();
  if (radio_) CloseHandle(radio_);
}

// ---- Radio ------------------------------------------------------------------

bool PuenteBluetoothImpl::AbrirRadio() {
  if (radio_) {
    BLUETOOTH_RADIO_INFO info = {sizeof(BLUETOOTH_RADIO_INFO)};
    if (BluetoothGetRadioInfo(radio_, &info) == ERROR_SUCCESS) return true;
    CloseHandle(radio_);  // apagada o quitada: se busca otra vez
    radio_ = nullptr;
  }
  BLUETOOTH_FIND_RADIO_PARAMS p = {sizeof(BLUETOOTH_FIND_RADIO_PARAMS)};
  HANDLE h = nullptr;
  HBLUETOOTH_RADIO_FIND f = BluetoothFindFirstRadio(&p, &h);
  if (!f) return false;
  BluetoothFindRadioClose(f);
  BLUETOOTH_RADIO_INFO info = {sizeof(BLUETOOTH_RADIO_INFO)};
  if (BluetoothGetRadioInfo(h, &info) != ERROR_SUCCESS) {
    CloseHandle(h);
    return false;
  }
  radio_ = h;
  local_ = info.address.ullLong;
  return true;
}

bool PuenteBluetoothImpl::Emparejado(BTH_ADDR a) {
  if (!radio_) return false;
  BLUETOOTH_DEVICE_INFO d = {sizeof(BLUETOOTH_DEVICE_INFO)};
  d.Address.ullLong = a;
  return BluetoothGetDeviceInfo(radio_, &d) == ERROR_SUCCESS && d.fAuthenticated;
}

// Sin permisos que pedir: en Windows una app de escritorio usa la radio sin diálogo.
// Con la radio apagada en Configuración, Windows no la enumera: «no hay».
EncodableMap PuenteBluetoothImpl::Consultar() {
  const bool hay = AbrirRadio();
  EncodableMap r = {{EncodableValue("hay"), EncodableValue(hay)},
                    {EncodableValue("permiso"), EncodableValue("concedido")},
                    {EncodableValue("encendido"), EncodableValue(hay)},
                    {EncodableValue("servidor"), EncodableValue(escucha_ != INVALID_SOCKET)}};
  if (hay) r[EncodableValue("direccion")] = EncodableValue(Texto(local_));
  return r;
}

// ---- Servidor ---------------------------------------------------------------

// Escucha en RFCOMM y publica el registro SDP «Serial Port» con ese nombre: el
// teléfono busca «W5RED» en el SDP del computador y, si lo ve, llama él.
std::optional<std::string> PuenteBluetoothImpl::Encender(const std::string& nombre, int preferido, int* canal) {
  if (escucha_ != INVALID_SOCKET) {
    *canal = canal_;
    return std::nullopt;
  }
  if (!wsa_) return "escucha";
  if (!AbrirRadio()) return "sin_adaptador";
  SOCKET s = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
  if (s == INVALID_SOCKET) return "escucha";
  SOCKADDR_BTH a = {};
  a.addressFamily = AF_BTH;
  a.port = preferido >= 1 && preferido <= 30 ? static_cast<ULONG>(preferido) : BT_PORT_ANY;
  if (bind(s, reinterpret_cast<sockaddr*>(&a), sizeof a) == SOCKET_ERROR) {
    a.port = BT_PORT_ANY;  // el preferido está ocupado: el que dé el sistema
    if (bind(s, reinterpret_cast<sockaddr*>(&a), sizeof a) == SOCKET_ERROR) {
      closesocket(s);
      return "escucha";
    }
  }
  int largo = sizeof a;
  if (getsockname(s, reinterpret_cast<sockaddr*>(&a), &largo) == SOCKET_ERROR || listen(s, 2) == SOCKET_ERROR) {
    closesocket(s);
    return "escucha";
  }
  sdp_direccion_ = a;
  sdp_csa_ = {};
  sdp_csa_.LocalAddr.lpSockaddr = reinterpret_cast<sockaddr*>(&sdp_direccion_);
  sdp_csa_.LocalAddr.iSockaddrLength = sizeof sdp_direccion_;
  sdp_csa_.iSocketType = SOCK_STREAM;
  sdp_csa_.iProtocol = BTHPROTO_RFCOMM;
  sdp_nombre_.assign(nombre.begin(), nombre.end());  // el nombre es ASCII («SENUS W5RED»)
  sdp_ = {};
  sdp_.dwSize = sizeof sdp_;
  sdp_.lpszServiceInstanceName = sdp_nombre_.data();
  sdp_.lpServiceClassId = const_cast<GUID*>(&kSerialPort);
  sdp_.dwNameSpace = NS_BTH;
  sdp_.dwNumberOfCsAddrs = 1;
  sdp_.lpcsaBuffer = &sdp_csa_;
  if (WSASetServiceW(&sdp_, RNRSERVICE_REGISTER, 0) == SOCKET_ERROR) {
    const int e = WSAGetLastError();
    closesocket(s);
    return "sdp:" + std::to_string(e);
  }
  sdp_hecho_ = true;
  escucha_ = s;
  canal_ = static_cast<int>(a.port);
  *canal = canal_;
  Aceptar(s);
  ArrancarReloj();
  Registro("SDP publicado: Serial Port «" + nombre + "» en el canal RFCOMM " + std::to_string(canal_));
  return std::nullopt;
}

void PuenteBluetoothImpl::Aceptar(SOCKET escucha) {
  auto cola = cola_;
  std::thread([this, cola, escucha] {
    for (;;) {
      SOCKADDR_BTH quien = {};
      int largo = sizeof quien;
      SOCKET c = accept(escucha, reinterpret_cast<sockaddr*>(&quien), &largo);
      if (c == INVALID_SOCKET) return;  // se cerró la escucha (apagar)
      const BTH_ADDR a = quien.btAddr;
      cola->Poner([this, c, a] {
        if (escucha_ == INVALID_SOCKET) {
          closesocket(c);
          return;
        }
        Alta(c, a);
      });
    }
  }).detach();
}

void PuenteBluetoothImpl::Apagar() {
  Desarmar();
  PararVigilancia();
  if (sdp_hecho_) {
    WSASetServiceW(&sdp_, RNRSERVICE_DELETE, 0);
    sdp_hecho_ = false;
  }
  if (escucha_ != INVALID_SOCKET) {
    closesocket(escucha_);  // el hilo de Aceptar sale con el error
    escucha_ = INVALID_SOCKET;
  }
  canal_ = 0;
  for (auto& [id, c] : conexiones_) shutdown(c->s, SD_BOTH);  // el lector ve el cierre y avisa
}

void PuenteBluetoothImpl::ArrancarReloj() {
  if (reloj_.joinable()) return;
  reloj_parar_ = false;
  auto cola = cola_;
  reloj_ = std::thread([this, cola] {
    std::unique_lock<std::mutex> g(reloj_m_);
    while (!reloj_cv_.wait_for(g, 1s, [this] { return reloj_parar_; })) {
      cola->Poner([this] { Tic(); });
    }
  });
}

void PuenteBluetoothImpl::PararReloj() {
  {
    std::lock_guard<std::mutex> g(reloj_m_);
    reloj_parar_ = true;
  }
  reloj_cv_.notify_all();
  if (reloj_.joinable()) reloj_.join();
}

void PuenteBluetoothImpl::Tic() {
  if (armado_) VigilarPar();
  if (Reloj::now() - ultima_vuelta_ >= kPausaVigilar) VueltaVigilar();
}

// ---- Llamar al teléfono -------------------------------------------------------

std::optional<std::string> PuenteBluetoothImpl::Vigilar(const EncodableList* direcciones, int64_t canal) {
  if (canal < 1 || canal > 30) return "canal";
  std::vector<std::string> l;
  if (direcciones) {
    for (const auto& v : *direcciones) {
      const auto* s = std::get_if<std::string>(&v);
      if (!s) continue;
      BTH_ADDR a;
      const std::string n = Normalizar(*s);
      if (!Leer(n, &a)) {
        Registro("vigilar: «" + *s + "» no es una dirección; se salta");
      } else if (std::find(l.begin(), l.end(), n) == l.end()) {
        l.push_back(n);
      }
    }
  }
  const bool otro_canal = static_cast<int>(canal) != canal_telefono_;
  vigiladas_ = l;
  canal_telefono_ = static_cast<int>(canal);
  for (auto it = intentos_.begin(); it != intentos_.end();) {
    if (otro_canal || std::find(l.begin(), l.end(), it->first) == l.end()) {
      Soltar(it->second->s);
      it = intentos_.erase(it);
    } else {
      ++it;
    }
  }
  for (auto it = ultimo_fallo_.begin(); it != ultimo_fallo_.end();) {
    it = std::find(l.begin(), l.end(), it->first) == l.end() ? ultimo_fallo_.erase(it) : std::next(it);
  }
  VueltaVigilar();
  return std::nullopt;
}

// Una vuelta: caduca lo que no contesta y llama a quien no tiene canal ni llamada en
// curso. A quien no está emparejado con este computador no se le llama (Windows
// sacaría su diálogo de PIN), salvo al que se está emparejando por el cable.
void PuenteBluetoothImpl::VueltaVigilar() {
  ultima_vuelta_ = Reloj::now();
  if (escucha_ == INVALID_SOCKET) return;
  const auto ahora = Reloj::now();
  for (auto it = intentos_.begin(); it != intentos_.end();) {
    if (ahora - it->second->desde >= kPlazoIntento) {
      AnotarFallo(it->first, kFalloPlazo);
      Soltar(it->second->s);
      it = intentos_.erase(it);
    } else {
      ++it;
    }
  }
  for (const auto& dir : vigiladas_) {
    if (intentos_.count(dir)) continue;
    bool con_canal = false;
    for (const auto& [id, c] : conexiones_) con_canal = con_canal || c->texto == dir;
    if (con_canal) continue;
    BTH_ADDR a;
    if (!Leer(dir, &a)) continue;
    if (!Emparejado(a) && !(armado_ && armado_->direccion == a)) {
      AnotarFallo(dir, kFalloSinEmparejar);
      continue;
    }
    Llamar(dir, a);
  }
}

void PuenteBluetoothImpl::Llamar(const std::string& dir, BTH_ADDR a) {
  SOCKET s = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
  if (s == INVALID_SOCKET) {
    AnotarFallo(dir, WSAGetLastError());
    return;
  }
  auto i = std::make_shared<Intento>();
  i->s = s;
  intentos_[dir] = i;
  const ULONG canal = static_cast<ULONG>(canal_telefono_);
  auto cola = cola_;
  std::thread([this, cola, i, dir, a, s, canal] {
    SOCKADDR_BTH d = {};
    d.addressFamily = AF_BTH;
    d.btAddr = a;
    d.port = canal;
    // Bloquea hasta que conteste, falle o el plazo cierre el socket desde la ventana.
    const int e = connect(s, reinterpret_cast<sockaddr*>(&d), sizeof d) == 0 ? 0 : WSAGetLastError();
    cola->Poner([this, dir, i, e] { FinLlamada(dir, i, e); });
  }).detach();
}

void PuenteBluetoothImpl::FinLlamada(const std::string& dir, std::shared_ptr<Intento> i, int error) {
  auto it = intentos_.find(dir);
  if (it == intentos_.end() || it->second != i) {
    Soltar(i->s);  // de un intento caducado: no se queda abierto a medias
    return;
  }
  intentos_.erase(it);
  const SOCKET s = i->s.exchange(INVALID_SOCKET);
  if (error != 0 || s == INVALID_SOCKET) {
    if (s != INVALID_SOCKET) closesocket(s);
    AnotarFallo(dir, error != 0 ? error : kFalloPlazo);
    return;
  }
  ultimo_fallo_.erase(dir);
  Registro(dir + ": contestó en el canal RFCOMM " + std::to_string(canal_telefono_));
  BTH_ADDR a;
  Leer(dir, &a);
  Alta(s, a);
}

void PuenteBluetoothImpl::PararVigilancia() {
  for (auto& [dir, i] : intentos_) Soltar(i->s);
  intentos_.clear();
  vigiladas_.clear();
  ultimo_fallo_.clear();
}

// Solo al cambiar: con el teléfono sin red, fallaría en cada vuelta.
void PuenteBluetoothImpl::AnotarFallo(const std::string& dir, int codigo) {
  auto it = ultimo_fallo_.find(dir);
  if (it != ultimo_fallo_.end() && it->second == codigo) return;
  ultimo_fallo_[dir] = codigo;
  std::string que;
  if (codigo == kFalloPlazo) que = "no contestó en " + std::to_string(kPlazoIntento.count()) + " s";
  else if (codigo == kFalloSinEmparejar) que = "no está emparejado con este computador: no se le llama";
  else que = "la llamada falló (WSA " + std::to_string(codigo) + ")";
  Registro(dir + ": " + que + "; se reintenta mientras esté en la lista");
}

// ---- Datos ------------------------------------------------------------------

// Un canal abierto, venga de donde venga: desde aquí sale igual hacia Dart. Un hilo
// lee y otro escribe; los dos solo hablan con la ventana por la cola.
void PuenteBluetoothImpl::Alta(SOCKET s, BTH_ADDR a) {
  auto c = std::make_shared<Conexion>();
  c->id = sig_id_++;
  c->s = s;
  c->direccion = a;
  c->texto = Texto(a);
  conexiones_[c->id] = c;
  ULONG mtu = 0;
  int largo = sizeof mtu;
  if (getsockopt(s, SOL_RFCOMM, SO_BTH_MTU, reinterpret_cast<char*>(&mtu), &largo) == SOCKET_ERROR) mtu = 0;
  auto cola = cola_;
  const int id = c->id;
  std::thread([this, cola, c, id] {
    std::vector<uint8_t> b(8192);
    for (;;) {
      const int n = recv(c->s, reinterpret_cast<char*>(b.data()), static_cast<int>(b.size()), 0);
      if (n <= 0) break;
      std::vector<uint8_t> d(b.begin(), b.begin() + n);
      cola->Poner([this, id, d = std::move(d)]() mutable {
        if (conexiones_.count(id)) {
          Avisar({{EncodableValue("e"), EncodableValue("datos")},
                  {EncodableValue("id"), EncodableValue(id)},
                  {EncodableValue("datos"), EncodableValue(std::move(d))}});
        }
      });
    }
    cola->Poner([this, id] { Cerrado(id); });
  }).detach();
  std::thread([cola, c] {
    std::unique_lock<std::mutex> g(c->m);
    int error = 0;
    for (;;) {
      c->cv.wait(g, [&] { return c->cerrar || !c->cola.empty(); });
      if (c->cola.empty()) {
        // Cerrado y sin nada pendiente. El socket lo cierra este hilo, el último que
        // lo usa: cerrarlo desde la ventana con un send en vuelo podría dejar que su
        // número se reutilice y escribir en otro.
        closesocket(c->s);
        return;
      }
      Escritura w = std::move(c->cola.front());
      c->cola.pop_front();
      g.unlock();
      if (error == 0 && !c->cerrar) {
        size_t hecho = 0;
        while (hecho < w.datos.size()) {
          const int n = send(c->s, reinterpret_cast<const char*>(w.datos.data() + hecho),
                             static_cast<int>(w.datos.size() - hecho), 0);
          if (n == SOCKET_ERROR) {
            error = WSAGetLastError();
            break;
          }
          hecho += static_cast<size_t>(n);
        }
      }
      const int fin = c->cerrar && error == 0 ? WSAENOTCONN : error;
      auto aviso = std::move(w.alAcabar);
      cola->Poner([aviso, fin] { aviso(fin); });
      g.lock();
    }
  }).detach();
  Avisar({{EncodableValue("e"), EncodableValue("conectado")},
          {EncodableValue("id"), EncodableValue(id)},
          {EncodableValue("direccion"), EncodableValue(c->texto)},
          {EncodableValue("emparejado"), EncodableValue(Emparejado(a))},
          {EncodableValue("mtu"), EncodableValue(static_cast<int32_t>(mtu))}});
}

// Completa cuando send() lo dejó en la pila Bluetooth de Windows (ella trocea por
// el MTU y lleva los créditos de RFCOMM).
void PuenteBluetoothImpl::Escribir(int id, std::vector<uint8_t> datos, std::shared_ptr<Resultado> r) {
  auto it = conexiones_.find(id);
  if (it == conexiones_.end()) {
    r->Error("escritura", "el canal no está abierto");
    return;
  }
  if (datos.empty()) {
    r->Success();
    return;
  }
  auto c = it->second;
  {
    std::lock_guard<std::mutex> g(c->m);
    c->cola.push_back({std::move(datos), [r](int e) {
                         if (e == 0) r->Success();
                         else r->Error("escritura", "WSA " + std::to_string(e));
                       }});
  }
  c->cv.notify_one();
}

void PuenteBluetoothImpl::Cerrado(int id) {
  auto it = conexiones_.find(id);
  if (it == conexiones_.end()) return;
  auto c = it->second;
  conexiones_.erase(it);
  {
    std::lock_guard<std::mutex> g(c->m);
    c->cerrar = true;  // lo pendiente sale con error y el escritor termina
  }
  c->cv.notify_one();  // el escritor falla lo pendiente, cierra el socket y termina
  Avisar({{EncodableValue("e"), EncodableValue("cerrado")}, {EncodableValue("id"), EncodableValue(id)}});
}

// ---- Emparejar ----------------------------------------------------------------

// Empareja con el teléfono que se acaba de mandar por el cable. El PIN lo contesta
// el callback, sin diálogo, tanto si llama el teléfono como si llamamos nosotros:
// mientras esté armado y sin emparejar, BluetoothAuthenticateDeviceEx arranca cada
// kPausaPar (uno a la vez). Un intento que falla no es el final: «reintento»; el
// final lo pone Dart con su plazo y lo que diga el teléfono por el cable.
std::optional<std::string> PuenteBluetoothImpl::Armar(const std::string& dir, const std::string& pin) {
  Desarmar();
  BTH_ADDR a;
  if (!Leer(dir, &a)) return "direccion";
  if (!AbrirRadio()) return "sin_adaptador";
  armado_ = Armado{a, Texto(a), pin};
  par_listo_ = false;
  par_desde_ = Reloj::time_point{};
  auto au = std::make_shared<Autentica>();
  au->cola = cola_;
  au->direccion = a;
  au->pin = pin;
  const std::string texto = Texto(a);
  const int gen = gen_par_;
  au->alContestar = [this, texto, gen](DWORD e) {
    if (gen == gen_par_) AvisarPar(texto, "pin", static_cast<int64_t>(e));
  };
  autenticas_.push_back(au);
  BLUETOOTH_DEVICE_INFO d = {sizeof(BLUETOOTH_DEVICE_INFO)};
  d.Address.ullLong = a;
  BluetoothGetDeviceInfo(radio_, &d);
  const DWORD e = BluetoothRegisterForAuthenticationEx(&d, &registro_auth_, &Contestar, au.get());
  if (e != ERROR_SUCCESS) {
    registro_auth_ = nullptr;
    Registro("no pude registrar quién contesta el PIN (" + std::to_string(e) + "): Windows lo preguntará en un diálogo");
  }
  AvisarPar(texto, "armado", 0);
  VigilarPar();
  ArrancarReloj();
  return std::nullopt;
}

void PuenteBluetoothImpl::Desarmar() {
  if (registro_auth_) {
    BluetoothUnregisterAuthentication(registro_auth_);
    registro_auth_ = nullptr;
  }
  armado_.reset();
  gen_par_++;  // lo que vuelva de un intento en curso ya no cuenta
  par_en_curso_ = false;
  par_listo_ = false;
}

void PuenteBluetoothImpl::VigilarPar() {
  if (!armado_ || par_listo_) return;
  if (Emparejado(armado_->direccion)) {
    par_listo_ = true;
    AvisarPar(armado_->texto, "ya", 0);
    VueltaVigilar();  // ya se le puede llamar: sin esperar a la vuelta
    return;
  }
  if (!par_en_curso_ && Reloj::now() - par_desde_ >= kPausaPar) ArrancarPar();
}

void PuenteBluetoothImpl::ArrancarPar() {
  par_en_curso_ = true;
  par_desde_ = Reloj::now();
  const HANDLE radio = radio_;
  const BTH_ADDR a = armado_->direccion;
  const std::string texto = armado_->texto;
  const int gen = gen_par_;
  auto cola = cola_;
  std::thread([this, cola, radio, a, texto, gen] {
    BLUETOOTH_DEVICE_INFO d = {sizeof(BLUETOOTH_DEVICE_INFO)};
    d.Address.ullLong = a;
    BluetoothGetDeviceInfo(radio, &d);
    // Sin ventana padre: con el callback registrado, Windows no saca su asistente.
    const DWORD e = BluetoothAuthenticateDeviceEx(nullptr, radio, &d, nullptr, MITMProtectionNotRequired);
    cola->Poner([this, texto, gen, e] {
      if (gen != gen_par_) return;
      par_en_curso_ = false;
      if (e == ERROR_SUCCESS) {
        par_listo_ = true;
        AvisarPar(texto, "hecho", 0);
        VueltaVigilar();
      } else {
        AvisarPar(texto, "reintento", static_cast<int64_t>(e));
      }
    });
  }).detach();
}

// ---- Órdenes ------------------------------------------------------------------

void PuenteBluetoothImpl::Atender(const flutter::MethodCall<EncodableValue>& llamada, std::unique_ptr<Resultado> r) {
  const auto* a = std::get_if<EncodableMap>(llamada.arguments());
  const std::string& m = llamada.method_name();
  if (m == "consultar") {
    r->Success(EncodableValue(Consultar()));
  } else if (m == "encender") {
    int canal = 0;
    const auto e = Encender(ArgTexto(a, "nombre", "SENUS"), static_cast<int>(ArgEntero(a, "canal", 10)), &canal);
    if (e) {
      const bool sdp = e->rfind("sdp", 0) == 0;
      r->Error(sdp ? "sdp" : *e, sdp ? "Windows no publicó el registro SDP (WSA " + e->substr(e->find(':') + 1) + ")" : *e);
    } else {
      r->Success(EncodableValue(canal));
    }
  } else if (m == "apagar") {
    Apagar();
    r->Success();
  } else if (m == "armarEmparejamiento") {
    const auto e = Armar(ArgTexto(a, "direccion"), ArgTexto(a, "pin"));
    if (e) r->Error(*e, *e);
    else r->Success();
  } else if (m == "vigilar") {
    const auto* v = Arg(a, "direcciones");
    const auto e = Vigilar(v ? std::get_if<EncodableList>(v) : nullptr, ArgEntero(a, "canal", 0));
    if (e) r->Error(*e, "canal fuera de 1..30");
    else r->Success();
  } else if (m == "desarmarEmparejamiento") {
    Desarmar();
    r->Success();
  } else if (m == "olvidar") {
    BTH_ADDR d;
    bool hecho = false;
    if (Leer(ArgTexto(a, "direccion"), &d)) {
      BLUETOOTH_ADDRESS b = {};
      b.ullLong = d;
      hecho = BluetoothRemoveDevice(&b) == ERROR_SUCCESS;
    }
    r->Success(EncodableValue(hecho));
  } else if (m == "escribir") {
    const auto* v = Arg(a, "datos");
    const auto* d = v ? std::get_if<std::vector<uint8_t>>(v) : nullptr;
    if (!d || !Arg(a, "id")) {
      r->Error("argumentos", "escribir");
      return;
    }
    Escribir(static_cast<int>(ArgEntero(a, "id", 0)), *d, std::shared_ptr<Resultado>(std::move(r)));
  } else if (m == "cortar") {
    auto it = conexiones_.find(static_cast<int>(ArgEntero(a, "id", 0)));
    if (it != conexiones_.end()) shutdown(it->second->s, SD_BOTH);  // el lector avisa «cerrado»
    r->Success();
  } else {
    r->NotImplemented();
  }
}

// ---- Fachada ------------------------------------------------------------------

PuenteBluetooth::PuenteBluetooth(flutter::BinaryMessenger* mensajero, HWND ventana)
    : impl_(std::make_unique<PuenteBluetoothImpl>(mensajero, ventana)) {}

PuenteBluetooth::~PuenteBluetooth() = default;

void PuenteBluetooth::Drenar() { impl_->Drenar(); }

void PuenteBluetooth::Apagar() { impl_->Apagar(); }
