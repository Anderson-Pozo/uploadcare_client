import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart';
import 'package:http_parser/http_parser.dart';
import 'package:meta/meta.dart';
import 'package:mime_type/mime_type.dart';
import 'package:flutter_uploadcare_client/src/concurrent_runner.dart';
import 'package:flutter_uploadcare_client/src/entities/entities.dart';
import 'package:flutter_uploadcare_client/src/mixins/mixins.dart';
import 'package:flutter_uploadcare_client/src/options.dart';

const int _kChunkSize = 5242880;
const int _kRecomendedMaxFilesizeForBaseUpload = 10000000;

typedef void ProgressListener(ProgressEntity progress);

/// Provides API for uploading files
class ApiUpload with OptionsShortcutMixin, TransportHelperMixin {
  final ClientOptions options;

  ApiUpload({
    @required this.options,
  }) : assert(options != null);

  /// Upload file [res] according to type
  /// if `String` makes [fromUrl] upload, otherwise make an `File` request according to size
  Future<String> auto(
    dynamic res, {
    bool storeMode,
    ProgressListener onProgress,
  }) async {
    if (res is File) {
      final file = res;
      final filesize = await file.length();

      if (filesize > _kRecomendedMaxFilesizeForBaseUpload)
        return multipart(
          file,
          storeMode: storeMode,
          onProgress: onProgress,
        );

      return base(
        file,
        storeMode: storeMode,
        onProgress: onProgress,
      );
    } else if (res is String && res.isNotEmpty) {
      return fromUrl(
        res,
        storeMode: storeMode,
        onProgress: onProgress,
      );
    }

    throw Exception('Make sure you passed File or URL string');
  }

  /// Make upload to `/base` endpoint
  ///
  /// [storeMode]`=null` - auto store
  /// [storeMode]`=true` - store file
  /// [storeMode]`=false` - keep file for 24h in storage
  /// [onProgress] subscribe to progress event
  Future<String> base(
    File file, {
    bool storeMode,
    ProgressListener onProgress,
  }) async {
    final filename = Uri.parse(file.path).pathSegments.last;
    final filesize = await file.length();

    ProgressEntity progress = ProgressEntity(0, filesize);

    final client =
        createMultipartRequest('POST', buildUri('$uploadUrl/base/'), false)
          ..fields.addAll({
            'UPLOADCARE_PUB_KEY': publicKey,
            'UPLOADCARE_STORE': resolveStoreModeParam(storeMode),
            if (options.useSignedUploads) ..._signUpload(),
          })
          ..files.add(
            MultipartFile(
              'file',
              file.openRead().transform(
                    StreamTransformer.fromHandlers(
                      handleData: (data, sink) {
                        final next = progress.copyWith(
                            uploaded: progress.uploaded + data.length);
                        final shouldCall = next.value > progress.value;
                        progress = next;

                        if (onProgress != null && shouldCall)
                          onProgress(progress);
                        sink.add(data);
                      },
                      handleDone: (sink) => sink.close(),
                    ),
                  ),
              filesize,
              filename: filename,
              contentType: MediaType.parse(mime(filename)),
            ),
          );

    return (await resolveStreamedResponse(client.send()))['file'] as String;
  }

  /// Make upload to `/multipart` endpoint
  Future<String> multipart(
    File file, {
    bool storeMode,
    ProgressListener onProgress,
    int maxConcurrentChunkRequests,
  }) async {
    maxConcurrentChunkRequests ??= options.multipartMaxConcurrentChunkRequests;

    final filename = Uri.parse(file.path).pathSegments.last;
    final filesize = await file.length();
    final mimeType = mime(filename);

    assert(filesize > _kRecomendedMaxFilesizeForBaseUpload,
        'Minimum file size to use with Multipart Uploads is 10MB');

    final startTransaction = createMultipartRequest(
        'POST', buildUri('$uploadUrl/multipart/start/'), false)
      ..fields.addAll({
        'UPLOADCARE_PUB_KEY': publicKey,
        'UPLOADCARE_STORE': resolveStoreModeParam(storeMode),
        'filename': filename,
        'size': filesize.toString(),
        'content_type': mimeType,
        if (options.useSignedUploads) ..._signUpload(),
      });

    final map = await resolveStreamedResponse(startTransaction.send());
    final urls = (map['parts'] as List).cast<String>();
    final uuid = map['uuid'] as String;

    ProgressEntity progress = ProgressEntity(0, urls.length);

    final actions = await Future.wait(List.generate(urls.length, (index) {
      final url = urls[index];
      final offset = index * _kChunkSize;
      final diff = filesize - offset;
      final bytesToRead = _kChunkSize < diff ? _kChunkSize : diff;

      return file
          .openRead(offset, offset + bytesToRead)
          .toList()
          .then((bytesList) => bytesList.expand((list) => list).toList())
          .then((bytes) => createRequest('PUT', buildUri(url), false)
            ..bodyBytes = bytes
            ..headers.addAll({
              'Content-Type': mimeType,
            }))
          .then((request) => () =>
              resolveStreamedResponseStatusCode(request.send())
                  .then((response) {
                if (onProgress != null)
                  onProgress(progress = progress.copyWith(
                    uploaded: progress.uploaded + 1,
                  ));
                return response;
              }));
    }));

    await ConcurrentRunner(maxConcurrentChunkRequests, actions).run();

    final finishTransaction = createMultipartRequest(
        'POST', buildUri('$uploadUrl/multipart/complete/'), false)
      ..fields.addAll({
        'UPLOADCARE_PUB_KEY': publicKey,
        'uuid': uuid,
        if (options.useSignedUploads) ..._signUpload(),
      });

    await resolveStreamedResponse(finishTransaction.send());

    return uuid;
  }

  /// Make upload to `/fromUrl` endpoint
  Future<String> fromUrl(
    String url, {
    bool storeMode,
    ProgressListener onProgress,
    Duration checkInterval = const Duration(seconds: 1),
  }) async {
    final request = createMultipartRequest(
      'POST',
      buildUri('$uploadUrl/from_url/'),
      false,
    )..fields.addAll({
        'pub_key': publicKey,
        'store': resolveStoreModeParam(storeMode),
        'source_url': url,
        if (options.useSignedUploads) ..._signUpload(),
      });

    final token =
        (await resolveStreamedResponse(request.send()))['token'] as String;

    String fileId;

    await for (UrlUploadStatusEntity response
        in _urlUploadStatusAsStream(token, checkInterval)) {
      if (response.status == UrlUploadStatusValue.Error)
        throw ClientException(response.errorMessage);

      if (response.status == UrlUploadStatusValue.Success)
        fileId = response.fileInfo.id;

      if (response.progress != null && onProgress != null)
        onProgress(response.progress);
    }

    return fileId;
  }

  Future<void> _statusTimerCallback(
    String token,
    Duration checkInterval,
    StreamController<UrlUploadStatusEntity> controller,
  ) async {
    final response = UrlUploadStatusEntity.fromJson(
      await resolveStreamedResponse(
        createRequest(
          'GET',
          buildUri(
            '$uploadUrl/from_url/status/',
            {
              'token': token,
            },
          ),
          false,
        ).send(),
      ),
    );

    controller.add(response);

    if (response.status == UrlUploadStatusValue.Progress) {
      return Timer(checkInterval,
          () => _statusTimerCallback(token, checkInterval, controller));
    }

    controller.close();
  }

  Stream<UrlUploadStatusEntity> _urlUploadStatusAsStream(
    String token,
    Duration checkInterval,
  ) {
    final StreamController<UrlUploadStatusEntity> controller =
        StreamController.broadcast();

    Timer(checkInterval,
        () => _statusTimerCallback(token, checkInterval, controller));

    return controller.stream;
  }

  Map<String, String> _signUpload() {
    final expire = DateTime.now()
            .add(options.signedUploadsSignatureLifetime)
            .millisecondsSinceEpoch ~/
        1000;

    final signature = md5.convert('$privateKey$expire'.codeUnits).toString();

    return {
      'signature': signature,
      'expire': expire.toString(),
    };
  }
}