// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'session.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$SessionImpl _$$SessionImplFromJson(Map<String, dynamic> json) =>
    _$SessionImpl(
      id: json['id'] as String,
      name: json['name'] as String,
      relay: json['relay'] as String,
      pairedAt: DateTime.parse(json['pairedAt'] as String),
      lastConnected: json['lastConnected'] == null
          ? null
          : DateTime.parse(json['lastConnected'] as String),
      isConnected: json['isConnected'] as bool? ?? false,
    );

Map<String, dynamic> _$$SessionImplToJson(_$SessionImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'relay': instance.relay,
      'pairedAt': instance.pairedAt.toIso8601String(),
      'lastConnected': instance.lastConnected?.toIso8601String(),
      'isConnected': instance.isConnected,
    };
