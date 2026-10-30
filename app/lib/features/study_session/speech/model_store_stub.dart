import 'model_store.dart';

int getOptimalThreadsImpl(int maxThreads) => maxThreads;

ModelStore createModelStore() =>
    throw UnsupportedError('No model store for this platform.');
