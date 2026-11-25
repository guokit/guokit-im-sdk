/// 读本地文件：io 平台用 dart:io，Web 不支持（条件导入隔离，Web 编译不引入 dart:io）。
library;

import 'dart:typed_data';

import 'file_reader_stub.dart'
    if (dart.library.io) 'file_reader_io.dart'
    as impl;

/// 当前平台能否按路径读文件。
bool get canReadFiles => impl.canReadFiles;

/// 读整个文件。
Future<Uint8List> readFileBytes(String path) => impl.readFileBytes(path);

/// 文件字节数。
Future<int> fileLength(String path) => impl.fileLength(path);

/// 打开文件流，边读边传，不整个读进内存。
Stream<List<int>> openFile(String path) => impl.openFile(path);
