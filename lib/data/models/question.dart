
import 'dart:convert';

class Question {
  final String? id;
  final int type;
  final String content;
  final String? options;
  final String answer;
  final int createdAt;
  final String bankName;
  final String? explanation; // Added from another table or context

  const Question({
    this.id,
    required this.type,
    required this.content,
    this.options,
    required this.answer,
    required this.createdAt,
    required this.bankName,
    this.explanation,
  });

  factory Question.fromMap(Map<String, dynamic> map) {
    return Question(
      id: map['id']?.toString(),
      type: map['type'] as int? ?? 0,
      content: map['content']?.toString() ?? '无内容',
      options: map['options']?.toString() ?? '[]',
      answer: map['standard_answer']?.toString() ?? '',
      createdAt: map['created_at'] as int? ?? 0,
      bankName: map['bank_name']?.toString() ?? '默认题库',
      explanation: map['explanation']?.toString(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type,
      'content': content,
      'options': options,
      'standard_answer': answer,
      'created_at': createdAt,
      'bank_name': bankName,
      'explanation': explanation,
    };
  }

  Question copyWith({
    String? id,
    int? type,
    String? content,
    String? options,
    String? answer,
    int? createdAt,
    String? bankName,
    String? explanation,
  }) {
    return Question(
      id: id ?? this.id,
      type: type ?? this.type,
      content: content ?? this.content,
      options: options ?? this.options,
      answer: answer ?? this.answer,
      createdAt: createdAt ?? this.createdAt,
      bankName: bankName ?? this.bankName,
      explanation: explanation ?? this.explanation,
    );
  }
}
