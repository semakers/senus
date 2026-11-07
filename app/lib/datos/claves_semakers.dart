// Las claves públicas ed25519 que SENUS acepta (§5.1 del diseño). Son 32 bytes
// en base64; la privada nunca está aquí.
//
// Dos claves reales, principal y reserva (2026-11-07, salida a producción):
// la principal firma lo que publica https://api.semakers.com; la reserva se
// guarda fuera de línea y solo se usa si hay que retirar la principal (SENUS ya
// la acepta, así que el cambio no pide una versión nueva). Se generaron en el
// entorno de desarrollo (cifradas, fuera de este repositorio).
//
// La de desarrollo solo vale con `--dart-define=SENUS_DESARROLLO=true`: es una
// constante de compilación, así que no se activa con una variable de entorno.

import 'dart:convert';
import 'dart:typed_data';

const bool modoDesarrollo = bool.fromEnvironment('SENUS_DESARROLLO');

/// La clave pública de desarrollo (la privada no está aquí).
const String clavePublicaDesarrollo =
    'ytB6X7wImGMc+JZS1vdVaTwXaWMzn/SwwSyendyI7Gk=';

const String clavePublicaPrincipal = 'yWzPQ0Fraqo95ff+KhrXZGFUF0SRFq/No+pieXom85w=';
const String clavePublicaReserva = 'Cwt0slloz1/NzL2YgeTpGXwnF7Qw5UGkN+obh8ljqAA=';

/// La URL del backend: el de producción. Las compilaciones de desarrollo pasan
/// `--dart-define=SENUS_BACKEND=<url del backend de desarrollo>`.
const String urlBackendPredeterminada = String.fromEnvironment(
  'SENUS_BACKEND',
  defaultValue: 'https://api.semakers.com',
);

Uint8List clavePublica(String base64Clave) {
  final b = base64.decode(base64Clave);
  if (b.length != 32) {
    throw ArgumentError('Una clave pública ed25519 son 32 bytes.');
  }
  return b;
}

/// Las claves aceptadas por esta compilación.
List<Uint8List> clavesAceptadas({bool desarrollo = modoDesarrollo}) => [
      if (clavePublicaPrincipal.isNotEmpty) clavePublica(clavePublicaPrincipal),
      if (clavePublicaReserva.isNotEmpty) clavePublica(clavePublicaReserva),
      if (desarrollo) clavePublica(clavePublicaDesarrollo),
    ];
