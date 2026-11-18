class XiaozhiConfig {
  final String id;
  final String name;
  final String websocketUrl;
  final String macAddress;
  final String token;
  final String clientId;
  
  XiaozhiConfig({
    required this.id,
    required this.name,
    required this.websocketUrl,
    required this.macAddress,
    required this.token,
    this.clientId = '',
  });
  
  factory XiaozhiConfig.fromJson(Map<String, dynamic> json) {
    return XiaozhiConfig(
      id: json['id'],
      name: json['name'],
      websocketUrl: json['websocketUrl'],
      macAddress: json['macAddress'],
      token: json['token'] ?? '',
      clientId: json['clientId'] ?? json['macAddress'] ?? '',
    );
  }
  
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'websocketUrl': websocketUrl,
      'macAddress': macAddress,
      'token': token,
      'clientId': clientId,
    };
  }
  
  XiaozhiConfig copyWith({
    String? name,
    String? websocketUrl,
    String? macAddress,
    String? token,
    String? clientId,
  }) {
    return XiaozhiConfig(
      id: id,
      name: name ?? this.name,
      websocketUrl: websocketUrl ?? this.websocketUrl,
      macAddress: macAddress ?? this.macAddress,
      token: token ?? this.token,
      clientId: clientId ?? this.clientId,
    );
  }
}

