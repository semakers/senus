// Códigos MTP que SENUS usa (DISENO.md §4.1). Son los que api/mtp.c de senew soporta.

// Operaciones.
const int opDeviceInfo       = 0x1001;
const int opOpenSession      = 0x1002;
const int opCloseSession     = 0x1003;
const int opStorageIds       = 0x1004;
const int opStorageInfo      = 0x1005;
const int opObjectHandles    = 0x1007;
const int opObjectInfo       = 0x1008;
const int opGetObject        = 0x1009;
const int opDeleteObject     = 0x100B;
const int opSendObjectInfo   = 0x100C;
const int opSendObject       = 0x100D;
const int opDevPropDesc      = 0x1014;
const int opDevPropValue     = 0x1015;
const int opGetPartialObject = 0x101B;

// Canal de gestión de senew (docs/contrato_canal_gestion.md). Operaciones de
// vendedor: un senew que las tiene las lista en OperationsSupported.
const int opSenInfo          = 0x9400;
const int opSenAjLeer        = 0x9401;
const int opSenAjPoner       = 0x9402;
const int opSenReloj         = 0x9403;
const int opSenVincular      = 0x9404;
const int opSenEntrarBl      = 0x9405;
const int opSenBtEstado      = 0x9406;
const int opSenBtEmparejar   = 0x9407; // desde senew 0.29.1
const int opSenApps          = 0x9408;

// Códigos de respuesta.
const int rOk              = 0x2001;
const int rGeneral         = 0x2002;
const int rSinSesion       = 0x2003;
const int rOpNo            = 0x2005;
const int rStorageMal      = 0x2008;
const int rHandleMal       = 0x2009;
const int rLlena           = 0x200C;
const int rProtegido       = 0x200D;
const int rSoloLectura     = 0x200E;
const int rDenegado        = 0x200F;    // el usuario dijo «No» en el teléfono
const int rOcupado         = 0x2019;    // teléfono aún no acepta la conexión
const int rParamMal        = 0x201D;    // dataset mal formado: no se aplicó nada
const int rSesionYa        = 0x201E;

// Device property.
const int dpNombreAmigo    = 0xD402;

// Storage IDs (api/mtp.h).
const int storageMemoria   = 0x00010001;
const int storageTarjeta   = 0x00020001;

// Formatos (los que senew enumera; api/mtp.c).
const int fmtIndef         = 0x3000;
const int fmtCarpeta       = 0x3001;
const int fmtTexto         = 0x3004;
const int fmtWav           = 0x3008;
const int fmtMp3           = 0x3009;
const int fmtJpeg          = 0x3801;
const int fmtPng           = 0x380B;

// Handle raíz especial de MTP: 0xFFFFFFFF.
const int handleRaiz = 0xFFFFFFFF;
