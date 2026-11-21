import 'dart:io';
import 'dart:typed_data';

const bool canReadFiles = true;

Future<Uint8List> readFileBytes(String path) => File(path).readAsBytes();
