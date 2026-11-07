// senus_dictado.c — el ayudante del dictado de SENUS: whisper.cpp en un proceso
// aparte, para que un fallo de ggml (aborta sin avisar) no se lleve la app.
//
//   senus_dictado --modelo M.bin --vad V.bin [--hilos 4] [--ventana 750] [--sin-gpu] [--registro]
//
// Habla por stdin/stdout. Al arrancar escribe una línea JSON:
//   {"ok":true,"listo":true,"version":"1.9.5","carga_ms":310}
// Cada petición: 12 bytes de cabecera y las muestras.
//   'W' '5' op 0  idioma[4]  n (u32 LE)  n floats de 32 bits LE, 16 kHz mono
//   op 1 = VAD          -> {"ok":true,"tramos":[[t0,t1],...]}            (t en milisegundos)
//   op 2 = TRANSCRIBIR  -> {"ok":true,"segmentos":[{"t":"…","ns":0.1,"lp":-0.3},...]}
//   op 0 = SALIR
// Si algo falla: {"ok":false,"fallo":"…"}. Con stdin cerrado (SENUS se fue) sale solo.
//
// Sale siempre con _exit: la salida normal corre los destructores de ggml, y
// ggml_metal_device_free aborta si queda memoria de Metal viva [medido].
//
// Nada del audio ni del texto va al disco ni al registro.

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "whisper.h"

#define MAX_MUESTRAS (16000u * 300u) /* 5 minutos: mucho más de lo que deja el servicio */

// La ventana corta (750 = 15 s) va el doble de rápido, pero con más de ~12 s de voz
// pierde frases [medido 1-nov, frases distintas: WER 27,6 % con 20 s de audio y
// 60,6 % con 50 s, frente a 13,3 % y 12,9 % con la ventana entera].
#define MUESTRAS_VENTANA_CORTA (12u * 16000u)

static bool registro = false;

static void callar(enum ggml_log_level nivel, const char *texto, void *dato) {
  (void)dato;
  if (registro || nivel == GGML_LOG_LEVEL_ERROR) fputs(texto, stderr);
}

static double ahora_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static bool leer(void *p, size_t n) {
  uint8_t *q = p;
  while (n) {
    ssize_t k = read(0, q, n);
    if (k <= 0) return false;
    q += k;
    n -= (size_t)k;
  }
  return true;
}

static void salir(int codigo) {
  fflush(stdout);
  _exit(codigo);
}

// JSON: los bytes de 0x80 en adelante van tal cual (UTF-8, o un trozo si whisper
// partió una letra; Dart lo decodifica tolerando eso).
static void escribir_texto(const char *s) {
  putchar('"');
  for (; *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\') {
      putchar('\\');
      putchar(c);
    } else if (c < 0x20) {
      printf("\\u%04x", c);
    } else {
      putchar(c);
    }
  }
  putchar('"');
}

static void fallo(const char *s) {
  fputs("{\"ok\":false,\"fallo\":", stdout);
  escribir_texto(s);
  fputs("}\n", stdout);
  fflush(stdout);
}

static float finito(float x) { return isfinite(x) ? x : 0.0f; }

static void hacer_vad(struct whisper_vad_context *vctx, const float *x, uint32_t n) {
  // Lo mismo que faster-whisper con VadOptions(min_silence_duration_ms=500,
  // speech_pad_ms=300), lo que usa bt/dictado/servicio.py.
  struct whisper_vad_params p = whisper_vad_default_params();
  p.threshold = 0.5f;
  p.min_speech_duration_ms = 0;
  p.min_silence_duration_ms = 500;
  p.max_speech_duration_s = 1e30f;
  p.speech_pad_ms = 300;
  p.samples_overlap = 0.0f;
  struct whisper_vad_segments *seg = whisper_vad_segments_from_samples(vctx, p, x, (int)n);
  if (!seg) {
    fallo("vad");
    return;
  }
  fputs("{\"ok\":true,\"tramos\":[", stdout);
  int k = whisper_vad_segments_n_segments(seg);
  for (int i = 0; i < k; i++) {
    // centisegundos a milisegundos
    printf("%s[%.0f,%.0f]", i ? "," : "", whisper_vad_segments_get_segment_t0(seg, i) * 10.0,
           whisper_vad_segments_get_segment_t1(seg, i) * 10.0);
  }
  fputs("]}\n", stdout);
  fflush(stdout);
  whisper_vad_free_segments(seg);
}

static void hacer_whisper(struct whisper_context *ctx, const float *x, uint32_t n, const char *idioma,
                          int hilos, int ventana) {
  struct whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  p.n_threads = hilos;
  p.language = idioma;
  p.detect_language = false;
  p.no_context = true;     // condition_on_previous_text=False
  p.no_timestamps = false; // con marcas: sin ellas se pierden frases en dictados largos
  p.temperature = 0.0f;    // sin reintentos que inventan
  p.temperature_inc = 0.0f;
  p.greedy.best_of = 1;
  p.audio_ctx = n > MUESTRAS_VENTANA_CORTA ? 0 : ventana; // 0 = la ventana entera, 30 s
  p.suppress_blank = true;
  p.suppress_nst = true;
  p.print_progress = false;
  p.print_realtime = false;
  p.print_timestamps = false;
  p.print_special = false;
  if (whisper_full(ctx, p, x, (int)n) != 0) {
    fallo("whisper_full");
    return;
  }
  whisper_token eot = whisper_token_eot(ctx);
  fputs("{\"ok\":true,\"segmentos\":[", stdout);
  int k = whisper_full_n_segments(ctx);
  for (int i = 0; i < k; i++) {
    double suma = 0;
    int cuenta = 0;
    int tokens = whisper_full_n_tokens(ctx, i);
    for (int j = 0; j < tokens; j++) {
      whisper_token_data d = whisper_full_get_token_data(ctx, i, j);
      if (d.id < eot) { // solo texto: fuera marcas y fichas especiales
        suma += d.plog;
        cuenta++;
      }
    }
    // la cuenta de faster-whisper: acumulado / (tokens + 1)
    double lp = cuenta ? suma / (cuenta + 1) : 0.0;
    fputs(i ? ",{\"t\":" : "{\"t\":", stdout);
    escribir_texto(whisper_full_get_segment_text(ctx, i));
    printf(",\"ns\":%.4f,\"lp\":%.4f}", finito(whisper_full_get_segment_no_speech_prob(ctx, i)), finito((float)lp));
  }
  fputs("]}\n", stdout);
  fflush(stdout);
}

int main(int argc, char **argv) {
  const char *modelo = NULL, *vad = NULL;
  int hilos = 4, ventana = 750;
  bool gpu = true;
  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--modelo") && i + 1 < argc) modelo = argv[++i];
    else if (!strcmp(argv[i], "--vad") && i + 1 < argc) vad = argv[++i];
    else if (!strcmp(argv[i], "--hilos") && i + 1 < argc) hilos = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--ventana") && i + 1 < argc) ventana = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--sin-gpu")) gpu = false;
    else if (!strcmp(argv[i], "--registro")) registro = true;
  }
  if (!modelo || !vad) {
    fallo("faltan --modelo y --vad");
    salir(2);
  }
  whisper_log_set(callar, NULL);

  double t0 = ahora_ms();
  struct whisper_context_params cp = whisper_context_default_params();
  cp.use_gpu = gpu;
  cp.flash_attn = false;
  struct whisper_context *ctx = whisper_init_from_file_with_params(modelo, cp);
  if (!ctx) {
    fallo("el modelo no carga");
    salir(3);
  }
  struct whisper_vad_context_params vp = whisper_vad_default_context_params();
  vp.n_threads = 2;
  vp.use_gpu = false;
  struct whisper_vad_context *vctx = whisper_vad_init_from_file_with_params(vad, vp);
  if (!vctx) {
    fallo("el VAD no carga");
    salir(3);
  }
  printf("{\"ok\":true,\"listo\":true,\"version\":\"%s\",\"carga_ms\":%.0f}\n", whisper_version(), ahora_ms() - t0);
  fflush(stdout);

  float *x = NULL;
  uint32_t capacidad = 0;
  for (;;) {
    uint8_t cab[12];
    if (!leer(cab, sizeof cab)) salir(0);
    if (cab[0] != 'W' || cab[1] != '5') {
      fallo("cabecera");
      salir(4);
    }
    uint8_t op = cab[2];
    if (op == 0) salir(0);
    char idioma[5] = {0};
    memcpy(idioma, cab + 4, 4);
    uint32_t n = (uint32_t)cab[8] | (uint32_t)cab[9] << 8 | (uint32_t)cab[10] << 16 | (uint32_t)cab[11] << 24;
    if (n > MAX_MUESTRAS) {
      fallo("demasiadas muestras");
      salir(4);
    }
    if (n > capacidad) {
      float *q = realloc(x, n * sizeof *x);
      if (!q) {
        fallo("sin memoria");
        salir(5);
      }
      x = q;
      capacidad = n;
    }
    if (n && !leer(x, n * sizeof *x)) salir(0);
    if (op == 1) hacer_vad(vctx, x, n);
    else if (op == 2) hacer_whisper(ctx, x, n, idioma, hilos, ventana);
    else fallo("orden desconocida");
  }
}
