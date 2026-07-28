import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';

import '../service/jh_service.dart';
import '../service/log.dart';

AISetting aiSetting = AISetting();

class AISetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  final RxBool enabled = false.obs;
  final RxString endpoint = ''.obs;
  final RxString model = ''.obs;
  final RxString apiKey = ''.obs;

  bool get isReady =>
      enabled.value && endpoint.value.trim().isNotEmpty && model.value.trim().isNotEmpty && apiKey.value.trim().isNotEmpty;

  @override
  ConfigEnum get configEnum => ConfigEnum.aiSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    enabled.value = map['enabled'] ?? enabled.value;
    if (map['endpoint'] != null) {
      endpoint.value = _normalizeEndpoint(map['endpoint'] as String);
    }
    model.value = (map['model'] ?? model.value).toString().trim();
    apiKey.value = (map['apiKey'] ?? apiKey.value).toString().trim();
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'enabled': enabled.value,
      'endpoint': endpoint.value,
      'model': model.value,
      'apiKey': apiKey.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> saveConfig({
    required bool enabled,
    required String endpoint,
    required String model,
    required String apiKey,
  }) async {
    log.debug('saveConfig: enabled=$enabled, endpoint=$endpoint, model=$model');
    this.enabled.value = enabled;
    this.endpoint.value = _normalizeEndpoint(endpoint);
    this.model.value = model.trim();
    this.apiKey.value = apiKey.trim();
    await saveBeanConfig();
  }

  String _normalizeEndpoint(String value) {
    String endpoint = value.trim();
    while (endpoint.endsWith('/')) {
      endpoint = endpoint.substring(0, endpoint.length - 1);
    }
    return endpoint;
  }
}
