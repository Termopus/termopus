// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'message.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

_$MessageImpl _$$MessageImplFromJson(Map<String, dynamic> json) =>
    _$MessageImpl(
      id: json['id'] as String,
      type: $enumDecode(_$MessageTypeEnumMap, json['type']),
      sender: $enumDecode(_$MessageSenderEnumMap, json['sender']),
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      language: json['language'] as String?,
      diffLines: (json['diffLines'] as List<dynamic>?)
          ?.map((e) => DiffLine.fromJson(e as Map<String, dynamic>))
          .toList(),
      action: json['action'] == null
          ? null
          : PendingAction.fromJson(json['action'] as Map<String, dynamic>),
      toolName: json['toolName'] as String?,
      toolStatus: json['toolStatus'] as String?,
      toolInput: json['toolInput'] as Map<String, dynamic>?,
      toolResult: json['toolResult'] as String?,
      toolError: json['toolError'] as String?,
      questions: (json['questions'] as List<dynamic>?)
          ?.map((e) => e as Map<String, dynamic>)
          .toList(),
      agentId: json['agentId'] as String?,
      agentType: json['agentType'] as String?,
      agentStatus: json['agentStatus'] as String?,
      transferId: json['transferId'] as String?,
      fileName: json['fileName'] as String?,
      mimeType: json['mimeType'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt(),
      transferProgress: (json['transferProgress'] as num?)?.toDouble(),
      localFilePath: json['localFilePath'] as String?,
      transferSuccess: json['transferSuccess'] as bool?,
    );

Map<String, dynamic> _$$MessageImplToJson(_$MessageImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'type': _$MessageTypeEnumMap[instance.type]!,
      'sender': _$MessageSenderEnumMap[instance.sender]!,
      'content': instance.content,
      'timestamp': instance.timestamp.toIso8601String(),
      'language': instance.language,
      'diffLines': instance.diffLines,
      'action': instance.action,
      'toolName': instance.toolName,
      'toolStatus': instance.toolStatus,
      'toolInput': instance.toolInput,
      'toolResult': instance.toolResult,
      'toolError': instance.toolError,
      'questions': instance.questions,
      'agentId': instance.agentId,
      'agentType': instance.agentType,
      'agentStatus': instance.agentStatus,
      'transferId': instance.transferId,
      'fileName': instance.fileName,
      'mimeType': instance.mimeType,
      'fileSize': instance.fileSize,
      'transferProgress': instance.transferProgress,
      'localFilePath': instance.localFilePath,
      'transferSuccess': instance.transferSuccess,
    };

const _$MessageTypeEnumMap = {
  MessageType.text: 'text',
  MessageType.code: 'code',
  MessageType.diff: 'diff',
  MessageType.action: 'action',
  MessageType.system: 'system',
  MessageType.toolUse: 'toolUse',
  MessageType.askQuestion: 'askQuestion',
  MessageType.claudeResponse: 'claudeResponse',
  MessageType.thinking: 'thinking',
  MessageType.subagentEvent: 'subagentEvent',
  MessageType.fileOffer: 'fileOffer',
  MessageType.fileProgress: 'fileProgress',
  MessageType.fileComplete: 'fileComplete',
  MessageType.sessionList: 'sessionList',
};

const _$MessageSenderEnumMap = {
  MessageSender.claude: 'claude',
  MessageSender.user: 'user',
  MessageSender.system: 'system',
};

_$DiffLineImpl _$$DiffLineImplFromJson(Map<String, dynamic> json) =>
    _$DiffLineImpl(
      content: json['content'] as String,
      type: $enumDecode(_$DiffTypeEnumMap, json['type']),
      lineNumber: (json['lineNumber'] as num).toInt(),
    );

Map<String, dynamic> _$$DiffLineImplToJson(_$DiffLineImpl instance) =>
    <String, dynamic>{
      'content': instance.content,
      'type': _$DiffTypeEnumMap[instance.type]!,
      'lineNumber': instance.lineNumber,
    };

const _$DiffTypeEnumMap = {
  DiffType.add: 'add',
  DiffType.remove: 'remove',
  DiffType.context: 'context',
};

_$PendingActionImpl _$$PendingActionImplFromJson(Map<String, dynamic> json) =>
    _$PendingActionImpl(
      id: json['id'] as String,
      prompt: json['prompt'] as String,
      options:
          (json['options'] as List<dynamic>).map((e) => e as String).toList(),
      responded: json['responded'] as bool? ?? false,
      response: json['response'] as String?,
    );

Map<String, dynamic> _$$PendingActionImplToJson(_$PendingActionImpl instance) =>
    <String, dynamic>{
      'id': instance.id,
      'prompt': instance.prompt,
      'options': instance.options,
      'responded': instance.responded,
      'response': instance.response,
    };
