/// A named collection (e.g. "Data Structures", "Operating Systems")
/// that groups related [Question]s together.
class QuestionBank {
  final int? id;
  final String name;
  final String? description;
  final int createdAt; // Unix epoch ms
  final int updatedAt; // Unix epoch ms

  const QuestionBank({
    this.id,
    required this.name,
    this.description,
    required this.createdAt,
    required this.updatedAt,
  });

  factory QuestionBank.fromMap(Map<String, dynamic> map) {
    return QuestionBank(
      id: map['id'] as int?,
      name: map['name'] as String,
      description: map['description'] as String?,
      createdAt: map['created_at'] as int,
      updatedAt: map['updated_at'] as int,
    );
  }

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'name': name,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
    if (id != null) map['id'] = id;
    if (description != null) map['description'] = description;
    return map;
  }

  QuestionBank copyWith({
    int? id,
    String? name,
    String? description,
    int? createdAt,
    int? updatedAt,
  }) {
    return QuestionBank(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
