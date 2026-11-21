/// guokit IM Flutter 客户端 SDK。
library;

export 'src/errors.dart';
export 'src/guokit_im.dart' show GuokitIm, ImConfig;
export 'src/models.dart';
export 'src/realtime.dart'
    show
        ImRealtime,
        ImRealtimeConnected,
        ImRealtimeConnecting,
        ImRealtimeDisconnected,
        ImRealtimeEvent,
        ImRealtimeFactory,
        ImRealtimePublication;
export 'src/store.dart' show ImStore, ImUpsertResult;
export 'src/store_memory.dart' show MemoryImStore;
