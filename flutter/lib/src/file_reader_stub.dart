import 'dart:typed_data';

const bool canReadFiles = false;

Future<Uint8List> readFileBytes(String path) =>
    throw UnsupportedError('当前平台不能按路径读文件，请用 sendImageBytes');
