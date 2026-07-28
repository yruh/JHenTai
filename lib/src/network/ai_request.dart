import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get/get_rx/src/rx_workers/rx_workers.dart';
import 'package:jhentai/src/setting/ai_setting.dart';

import '../service/jh_service.dart';
import '../setting/network_setting.dart';

AIRequest aiRequest = AIRequest();

class AIRequest with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  late final Dio _dio;
  final List<Worker> _workers = <Worker>[];

  @override
  List<JHLifeCircleBean> get initDependencies => super.initDependencies..addAll([networkSetting, aiSetting]);

  @override
  Future<void> doInitBean() async {
    _dio = Dio(BaseOptions(
      connectTimeout: Duration(milliseconds: networkSetting.connectTimeout.value),
      receiveTimeout: Duration(milliseconds: networkSetting.receiveTimeout.value),
    ));

    _workers.add(ever(networkSetting.connectTimeout, (_) {
      setConnectTimeout(networkSetting.connectTimeout.value);
    }));
    _workers.add(ever(networkSetting.receiveTimeout, (_) {
      setReceiveTimeout(networkSetting.receiveTimeout.value);
    }));
  }

  @override
  Future<void> doAfterBeanReady() async {}

  void setConnectTimeout(int connectTimeout) {
    _dio.options.connectTimeout = Duration(milliseconds: connectTimeout);
  }

  void setReceiveTimeout(int receiveTimeout) {
    _dio.options.receiveTimeout = Duration(milliseconds: receiveTimeout);
  }

  /// Disposes GetX timeout workers. Not part of [JHLifeCircleBean]; call only if a
  /// future lifecycle path needs explicit teardown.
  void disposeWorkers() {
    for (final Worker worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
  }

  /// Sends a chat completion request and returns the assistant message as a JSON object.
  ///
  /// Accepts plain JSON or markdown-fenced JSON in `choices[0].message.content`.
  /// Throws [FormatException] when the content is missing or is not a JSON object.
  Future<Map<String, dynamic>> requestJson({
    required String systemPrompt,
    required String userPrompt,
  }) async {
    if (!aiSetting.isReady) {
      throw StateError('AI settings are incomplete');
    }

    final Response response = await _dio.post(
      '${aiSetting.endpoint.value}/chat/completions',
      options: Options(
        contentType: Headers.jsonContentType,
        headers: {
          'Authorization': 'Bearer ${aiSetting.apiKey.value}',
        },
      ),
      data: {
        'model': aiSetting.model.value,
        'temperature': 0,
        'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
      },
    );

    return _extractJsonObject(response.data);
  }

  Map<String, dynamic> _extractJsonObject(dynamic responseData) {
    if (responseData is! Map) {
      throw const FormatException('AI response is not a JSON object');
    }

    final dynamic choices = responseData['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const FormatException('AI response is missing choices[0]');
    }

    final dynamic firstChoice = choices[0];
    if (firstChoice is! Map) {
      throw const FormatException('AI response choices[0] is not a JSON object');
    }

    final dynamic message = firstChoice['message'];
    if (message is! Map) {
      throw const FormatException('AI response is missing choices[0].message');
    }

    final dynamic content = message['content'];
    if (content is! String) {
      throw const FormatException('AI response is missing choices[0].message.content');
    }

    return _parseObjectJson(content);
  }

  /// Parses plain JSON or markdown-fenced JSON and requires a top-level object.
  Map<String, dynamic> _parseObjectJson(String raw) {
    final String text = _stripMarkdownJsonFence(raw);

    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('AI response content is not valid JSON: $e');
    }

    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }

    throw FormatException('AI response content must be a JSON object, got ${decoded.runtimeType}');
  }

  /// Strips a markdown code fence when present (` ``` `, ` ```json `, etc.).
  ///
  /// Prefers an embedded fenced block if the model wraps JSON in prose; otherwise
  /// trims a whole-content fence; otherwise returns trimmed plain text.
  String _stripMarkdownJsonFence(String raw) {
    final String text = raw.trim();

    // Embedded fence anywhere in the content (optionally with a language tag).
    final RegExp embeddedFence = RegExp(r'```(?:[a-zA-Z0-9_+-]*)?\s*\r?\n([\s\S]*?)\r?\n\s*```');
    final RegExpMatch? embeddedMatch = embeddedFence.firstMatch(text);
    if (embeddedMatch != null) {
      return embeddedMatch.group(1)!.trim();
    }

    if (!text.startsWith('```')) {
      return text;
    }

    // Whole-content fence without a required trailing newline after the opener.
    String body = text.substring(3);
    final int firstNewline = body.indexOf('\n');
    if (firstNewline != -1) {
      // Drop optional language tag on the opening fence line.
      final String firstLine = body.substring(0, firstNewline).trim();
      if (RegExp(r'^[a-zA-Z0-9_+-]*$').hasMatch(firstLine)) {
        body = body.substring(firstNewline + 1);
      }
    }
    body = body.trimRight();
    if (body.endsWith('```')) {
      body = body.substring(0, body.length - 3).trimRight();
    }
    return body.trim();
  }
}
