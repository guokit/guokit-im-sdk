/// 按平台选默认存储：有 dart:io（iOS / Android）用 SQLite，否则（Web）用内存。
///
/// 用条件导入隔离，Web 编译不会引入 sqflite 与 dart:io。
library;

import 'store.dart';
import 'store_factory_memory.dart'
    if (dart.library.io) 'store_factory_sqlite.dart'
    as impl;

/// 创建当前平台的默认存储（未打开，调用方再 `open(userId)`）。
ImStore createDefaultStore() => impl.createStore();
