import 'dart:io';
import 'dart:typed_data';

const bool canReadFiles = true;

Future<Uint8List> readFileBytes(String path) => File(path).readAsBytes();

Future<int> fileLength(String path) => File(path).length();

Stream<List<int>> openFile(String path) => File(path).openRead();
