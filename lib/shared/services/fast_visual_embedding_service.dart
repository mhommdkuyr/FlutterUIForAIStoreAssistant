import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import 'visual_embedding_service.dart';

/// MobileCLIP2-S0 fast Android runtime.
///
/// The official S0 checkpoint uses RGB float32 in [0,1] with mean=(0,0,0)
/// and std=(1,1,1). The exported metadata in this repository is retained for
/// provenance, but the runtime contract is explicitly pinned to the official
/// S0 preprocessing so an export-tool normalization mistake cannot silently
/// poison every product embedding.
class FastMobileVisionEmbeddingService implements VisualEmbeddingService {
  static const assetPath = 'assets/models/mobileclip2/mobileclip2_s0_vision.onnx';
  static const externalDataAssetPath = 'assets/models/mobileclip2/mobileclip2_s0_vision.onnx.data';
  static const metadataAssetPath = 'assets/models/mobileclip2/model_metadata.json';
  static const modelContractVersion = 'mobileclip2_s0_vision_onnx_v4_fastscan_s0_preprocess';

  final OnnxRuntime _runtime = OnnxRuntime();
  OrtSession? _session;
  MobileClip2ModelContract? _contract;
  String? _inputName;
  String? _outputName;
  String? _runtimeModelPath;
  String? _runtimeExternalDataPath;
  Object? _initializationError;
  Object? _lastInferenceError;
  Future<void> _inferenceQueue = Future<void>.value();
  bool _disposed = false;

  bool get isInitialized => _session != null;
  Object? get initializationError => _initializationError;
  Object? get lastInferenceError => _lastInferenceError;
  MobileClip2ModelContract? get contract => _contract;

  @override
  int get embeddingLength => isInitialized ? 512 * 4 : 0;
  @override
  String get modelVersion => modelContractVersion;
  @override
  double get recommendedMinConfidence => 0.45;

  Future<void> initialize() async {
    _initializationError = null;
    _disposed = false;
    try {
      final raw = await rootBundle.loadString(metadataAssetPath);
      final metadata = jsonDecode(raw) as Map<String, dynamic>;
      final inputSize = metadata['input_size'];
      final normalization = metadata['normalization'];
      if (inputSize is! List || inputSize.length != 2 || inputSize[0] != 224 || inputSize[1] != 224 || normalization is! Map<String, dynamic>) {
        throw StateError('MobileCLIP2-S0 metadata is invalid.');
      }
      final mean = normalization['mean'];
      final std = normalization['std'];
      if (mean is! List || std is! List || mean.length != 3 || std.length != 3 || metadata['embedding_dimension'] != 512 || metadata['l2_normalized_required'] != true || metadata['onnx_opset'] != 18) {
        throw StateError('MobileCLIP2-S0 metadata shape/contract is invalid.');
      }

      // Do not use metadata mean/std here. Apple documents S0/S2/B with
      // image_mean=(0,0,0), image_std=(1,1,1); the metadata is retained as
      // export provenance only.
      _contract = const MobileClip2ModelContract(
        inputSize: 224,
        mean: [0.0, 0.0, 0.0],
        std: [1.0, 1.0, 1.0],
        embeddingDimensions: 512,
        l2NormalizedRequired: true,
        onnxOpset: 18,
      );

      final modelAsset = await rootBundle.load(assetPath);
      final dataAsset = await rootBundle.load(externalDataAssetPath);
      if (modelAsset.lengthInBytes == 0 || dataAsset.lengthInBytes == 0) throw StateError('MobileCLIP2 model or external data is empty.');

      final root = Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}mobileclip2_fast');
      await root.create(recursive: true);
      final modelFile = File('${root.path}${Platform.pathSeparator}mobileclip2_s0_vision.onnx');
      final dataFile = File('${root.path}${Platform.pathSeparator}mobileclip2_s0_vision.onnx.data');
      await modelFile.writeAsBytes(modelAsset.buffer.asUint8List(modelAsset.offsetInBytes, modelAsset.lengthInBytes), flush: true);
      await dataFile.writeAsBytes(dataAsset.buffer.asUint8List(dataAsset.offsetInBytes, dataAsset.lengthInBytes), flush: true);
      _runtimeModelPath = modelFile.path;
      _runtimeExternalDataPath = dataFile.path;

      final available = await _runtime.getAvailableProviders();
      final providers = <OrtProvider>[if (available.contains(OrtProvider.XNNPACK)) OrtProvider.XNNPACK, OrtProvider.CPU];
      final options = OrtSessionOptions(intraOpNumThreads: 4, interOpNumThreads: 1, useArena: true, providers: providers);
      final session = await _runtime.createSession(modelFile.path, options: options);
      try {
        if (session.inputNames.length != 1 || session.outputNames.length != 1) throw StateError('MobileCLIP2 runtime must expose exactly one input and one output.');
        _inputName = session.inputNames.single;
        _outputName = session.outputNames.single;
        final inputShape = _readShape(await session.getInputInfo(), _inputName!, 'input');
        final outputShape = _readShape(await session.getOutputInfo(), _outputName!, 'output');
        final layout = MobileClip2ModelContract.detectGraphLayout(inputShape, 224);
        if (!MobileClip2ModelContract.isSingleEmbeddingShape(outputShape, 512)) throw StateError('MobileCLIP2 output shape $outputShape must be [1,512] or [-1,512].');
        _contract = _contract!.withGraphLayout(layout);
        await _smokeTest(session);
        _session = session;
      } catch (_) {
        await session.close();
        rethrow;
      }
    } catch (error) {
      _initializationError = error;
      _session = null;
      rethrow;
    }
  }

  List<int> _readShape(List<Map<String, dynamic>> infos, String name, String label) {
    Map<String, dynamic>? info;
    for (final item in infos) { if (item['name'] == name) { info = item; break; } }
    info ??= infos.length == 1 ? infos.single : null;
    if (info == null || info['shape'] is! List) throw StateError('MobileCLIP2 $label shape is unavailable for $name.');
    return (info['shape'] as List).map((v) { if (v is! num) throw StateError('MobileCLIP2 $label shape contains a non-numeric dimension.'); return v.toInt(); }).toList(growable: false);
  }

  Future<void> _smokeTest(OrtSession session) async {
    final shape = _contract!.layout == 'NHWC' ? [1,224,224,3] : [1,3,224,224];
    final input = await OrtValue.fromList(Float32List(224 * 224 * 3), shape);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({_inputName!: input});
      final output = outputs[_outputName!];
      if (output == null) throw StateError('MobileCLIP2 smoke test returned no output.');
      final values = (await output.asFlattenedList()).cast<num>();
      if (values.length != 512 || values.any((v) => !v.toDouble().isFinite)) throw StateError('MobileCLIP2 smoke test returned invalid output.');
    } finally {
      await input.dispose();
      if (outputs != null) for (final output in outputs.values) await output.dispose();
    }
  }

  @override
  Future<Uint8List?> embedFile(String path) async {
    if (_session == null) { _lastInferenceError = StateError('MobileCLIP2 fast ONNX session is unavailable.'); return null; }
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) return null;
      final oriented = img.bakeOrientation(decoded);
      final crop = min(oriented.width, oriented.height);
      final cropped = img.copyCrop(oriented, x: (oriented.width - crop) ~/ 2, y: (oriented.height - crop) ~/ 2, width: crop, height: crop);
      final resized = img.copyResize(cropped, width: 224, height: 224, interpolation: img.Interpolation.linear);
      return _run(_imageTensor(resized));
    } catch (error) { _lastInferenceError = error; return null; }
  }

  Future<Uint8List?> embedFrameWithRotation(CameraImage image, {int rotationDegrees = 0}) async {
    if (_session == null) { _lastInferenceError = StateError('MobileCLIP2 fast ONNX session is unavailable.'); return null; }
    try {
      final tensor = switch (image.format.group) {
        ImageFormatGroup.yuv420 => _yuvTensor(image, rotationDegrees),
        ImageFormatGroup.bgra8888 => _bgraTensor(image, rotationDegrees),
        _ => throw StateError('Unsupported camera image format: ${image.format.group}'),
      };
      return _run(tensor);
    } catch (error) { _lastInferenceError = error; return null; }
  }

  @override
  Future<Uint8List?> embedFrame(CameraImage image) => embedFrameWithRotation(image);

  Float32List _imageTensor(img.Image image) {
    final tensor = Float32List(224 * 224 * 3);
    for (var y = 0; y < 224; y++) for (var x = 0; x < 224; x++) { final p = image.getPixel(x, y); _writePixel(tensor, y, x, p.r.toDouble(), p.g.toDouble(), p.b.toDouble()); }
    return tensor;
  }

  Float32List _yuvTensor(CameraImage image, int rotationDegrees) {
    final w = image.width, h = image.height;
    if (w <= 0 || h <= 0 || image.planes.length < 3) throw StateError('Invalid YUV420 camera frame.');
    final crop = min(w, h), left = (w - crop) ~/ 2, top = (h - crop) ~/ 2;
    final yp = image.planes[0], up = image.planes[1], vp = image.planes[2], uvStep = up.bytesPerPixel ?? 1;
    final input = Float32List(224 * 224 * 3);
    final rotation = ((rotationDegrees % 360) + 360) % 360;
    for (var oy = 0; oy < 224; oy++) for (var ox = 0; ox < 224; ox++) {
      final p = ox * crop ~/ 224, q = oy * crop ~/ 224;
      late int sx, sy;
      switch (rotation) { case 90: sx = left + q; sy = top + crop - 1 - p; break; case 180: sx = left + crop - 1 - p; sy = top + crop - 1 - q; break; case 270: sx = left + crop - 1 - q; sy = top + p; break; default: sx = left + p; sy = top + q; }
      final x = sx.clamp(0, w - 1), y = sy.clamp(0, h - 1), yi = y * yp.bytesPerRow + x, ur = y >> 1, uc = x >> 1, ui = ur * up.bytesPerRow + uc * uvStep, vi = ur * vp.bytesPerRow + uc * uvStep;
      final yv = yi < yp.bytes.length ? yp.bytes[yi] : 0, u = ui < up.bytes.length ? up.bytes[ui] - 128 : 0, v = vi < vp.bytes.length ? vp.bytes[vi] - 128 : 0;
      _writePixel(input, oy, ox, (yv + 1.402*v).clamp(0,255).toDouble(), (yv - 0.344136*u - 0.714136*v).clamp(0,255).toDouble(), (yv + 1.772*u).clamp(0,255).toDouble());
    }
    return input;
  }

  Float32List _bgraTensor(CameraImage image, int rotationDegrees) {
    final w=image.width,h=image.height; if(w<=0||h<=0||image.planes.isEmpty) throw StateError('Invalid BGRA camera frame.');
    final crop=min(w,h),left=(w-crop)~/2,top=(h-crop)~/2,plane=image.planes[0],bytes=plane.bytes,input=Float32List(224*224*3),rotation=((rotationDegrees%360)+360)%360;
    for(var oy=0;oy<224;oy++) for(var ox=0;ox<224;ox++){final p=ox*crop~/224,q=oy*crop~/224;late int sx,sy;switch(rotation){case 90:sx=left+q;sy=top+crop-1-p;break;case 180:sx=left+crop-1-p;sy=top+crop-1-q;break;case 270:sx=left+crop-1-q;sy=top+p;break;default:sx=left+p;sy=top+q;}final base=sy*plane.bytesPerRow+sx*4;if(base<0||base+3>=bytes.length){_writePixel(input,oy,ox,0,0,0);continue;}_writePixel(input,oy,ox,bytes[base+2].toDouble(),bytes[base+1].toDouble(),bytes[base].toDouble());}
    return input;
  }

  void _writePixel(Float32List tensor, int row, int col, double r, double g, double b) {
    final rv=r/255.0,gv=g/255.0,bv=b/255.0,offset=row*224+col;
    if(_contract!.layout=='NHWC'){final base=offset*3;tensor[base]=rv;tensor[base+1]=gv;tensor[base+2]=bv;}else{const plane=224*224;tensor[offset]=rv;tensor[plane+offset]=gv;tensor[2*plane+offset]=bv;}
  }

  Future<Uint8List?> _run(Float32List tensor) {
    if (_disposed) return Future.value(null);
    final completer=Completer<Uint8List?>();
    _inferenceQueue=_inferenceQueue.then((_) async {try{completer.complete(await _runLocked(tensor));}catch(e,st){_lastInferenceError=e;completer.completeError(e,st);}});
    return completer.future.catchError((_)=>null);
  }

  Future<Uint8List?> _runLocked(Float32List tensor) async {
    final session=_session,inputName=_inputName,outputName=_outputName;if(session==null||inputName==null||outputName==null)return null;
    final input=await OrtValue.fromList(tensor,_contract!.layout=='NHWC'?[1,224,224,3]:[1,3,224,224]);Map<String,OrtValue>? outputs;
    try{outputs=await session.run({inputName:input});final output=outputs[outputName];if(output==null)throw StateError('MobileCLIP2 output missing.');final values=(await output.asFlattenedList()).cast<num>().map((v)=>v.toDouble()).toList(growable:false);if(values.length!=512||values.any((v)=>!v.isFinite))throw StateError('MobileCLIP2 embedding invalid.');final embedding=Float32List.fromList(values);var norm=0.0;for(final v in embedding)norm+=v*v;norm=sqrt(norm);if(norm<1e-10)throw StateError('MobileCLIP2 zero embedding.');for(var i=0;i<512;i++)embedding[i]/=norm;_lastInferenceError=null;return embedding.buffer.asUint8List();}catch(e){_lastInferenceError=e;return null;}finally{await input.dispose();if(outputs!=null)for(final output in outputs.values)await output.dispose();}
  }

  @override double similarity(Uint8List a, Uint8List b){if(a.length!=2048||b.length!=2048)return 0.0;final fa=a.buffer.asFloat32List(a.offsetInBytes,512),fb=b.buffer.asFloat32List(b.offsetInBytes,512);var dot=0.0;for(var i=0;i<512;i++)dot+=fa[i]*fb[i];return dot.clamp(0.0,1.0);}
  @override Future<void> dispose()async{_disposed=true;_inferenceQueue=_inferenceQueue.then((_)async{await _session?.close();_session=null;});await _inferenceQueue;for(final p in <String>[if(_runtimeModelPath!=null)_runtimeModelPath!,if(_runtimeExternalDataPath!=null)_runtimeExternalDataPath!]){try{final f=File(p);if(await f.exists())await f.delete();}catch(_){}}_runtimeModelPath=null;_runtimeExternalDataPath=null;}
}

class FastVisualEmbeddingProvider extends VisualEmbeddingProvider {
  final FastMobileVisionEmbeddingService _fast=FastMobileVisionEmbeddingService();bool _ready=false;
  @override bool get isOnnxActive=>_ready;@override Object? get initializationError=>_fast.initializationError;@override Object? get lastInferenceError=>_fast.lastInferenceError;@override String get modelVersion=>_fast.modelVersion;@override double get recommendedMinConfidence=>_fast.recommendedMinConfidence;@override int get embeddingLength=>_fast.embeddingLength;
  @override Future<void> initialize()async{try{await _fast.initialize();_ready=true;}catch(_){_ready=false;rethrow;}}
  @override Future<Uint8List?> embedFile(String path)=>_ready?_fast.embedFile(path):Future.value(null);
  @override Future<Uint8List?> embedFrame(CameraImage image)=>_ready?_fast.embedFrame(image):Future.value(null);
  Future<Uint8List?> embedFrameWithRotation(CameraImage image,{required int rotationDegrees})=>_ready?_fast.embedFrameWithRotation(image,rotationDegrees:rotationDegrees):Future.value(null);
  @override double similarity(Uint8List a,Uint8List b)=>_ready?_fast.similarity(a,b):0.0;
  @override Future<void> dispose()async{_ready=false;await _fast.dispose();}
}
