import '../application/exam/exam_mutation_command.dart';
import '../data/models/question_draft.dart';
import '../data/models/question_parse_mode.dart';
import '../data/repositories/ai_engine_repository.dart';
import '../data/repositories/question_repository.dart';
import 'import_pipeline/text_question_region.dart';
import 'ai_direct_call_service.dart';
import 'ai_task_resume_coordinator.dart';
import 'ai_text_generation_service.dart';
import 'ai_text_parse_service.dart';
import 'ai_vision_parse_service.dart';
import 'structured_question_merge_service.dart';
import 'task_manager.dart';

class AiService {
  factory AiService({
    required AiEngineRepository engineRepository,
    TaskManager? taskManager,
    QuestionRepository? questionRepository,
  }) {
    final visionParseService = AiVisionParseService(
      engineRepository: engineRepository,
    );
    return AiService._(
      directCallService: AiDirectCallService(
        engineRepository: engineRepository,
        visionParseService: visionParseService,
      ),
      questionMergeService: StructuredQuestionMergeService(
        engineRepository: engineRepository,
      ),
      textGenerationService: AiTextGenerationService(
        engineRepository: engineRepository,
        questionRepository: questionRepository,
      ),
      textParseService: AiTextParseService(
        engineRepository: engineRepository,
        taskManager: taskManager,
      ),
      visionParseService: visionParseService,
    );
  }

  const AiService._({
    required AiDirectCallService directCallService,
    required StructuredQuestionMergeService questionMergeService,
    required AiTextGenerationService textGenerationService,
    required AiTextParseService textParseService,
    required AiVisionParseService visionParseService,
  })  : _directCallService = directCallService,
        _questionMergeService = questionMergeService,
        _textGenerationService = textGenerationService,
        _textParseService = textParseService,
        _visionParseService = visionParseService;

  final AiDirectCallService _directCallService;
  final StructuredQuestionMergeService _questionMergeService;
  final AiTextGenerationService _textGenerationService;
  final AiTextParseService _textParseService;
  final AiVisionParseService _visionParseService;

  Future<String> callLlmApi(String prompt, {List<String>? imagePaths}) async {
    return _directCallService.call(prompt, imagePaths: imagePaths);
  }

  Future<void> resumeTask(String taskId) async {
    await AiTaskResumeCoordinator(
      parseTextBatches: parseMicroBatches,
      parseVisionImages: parseImagesWithVision,
    ).resume(taskId);
  }

  Future<String> judgeAnswer(
      String question, String standardAnswer, String userAnswer) async {
    return _textGenerationService.judgeAnswer(
      question,
      standardAnswer,
      userAnswer,
    );
  }

  Future<List<QuestionDraft>> generateQuestions(String topic,
      {int count = 1, int type = 0}) async {
    return _textGenerationService.generateQuestions(
      topic,
      count: count,
      type: type,
    );
  }

  Future<Map<String, String>> answerSingleQuestion(
      Map<String, dynamic> question) async {
    return _textGenerationService.answerSingleQuestion(question);
  }

  Future<List<QuestionDraft>> generateExamPaper(
      {required String topic,
      required int singleCount,
      required int fillCount,
      required int shortCount,
      String? customPrompt}) {
    return runExamGeneration(
      () => _textGenerationService.generateExamPaper(
        topic: topic,
        singleCount: singleCount,
        fillCount: fillCount,
        shortCount: shortCount,
        customPrompt: customPrompt,
      ),
    );
  }

  // --- 错题重练引擎：根据错题生成新题并存入指定题库 ---
  Future<List<QuestionDraft>> generateAndSaveQuestionsFromMistakes(
      {String targetBankName = '🔥 弱点突击训练营',
      int limit = 30,
      int count = 10}) async {
    return _textGenerationService.generateAndSaveQuestionsFromMistakes(
      targetBankName: targetBankName,
      limit: limit,
      count: count,
    );
  }

  Future<List<Map<String, dynamic>>> parseTextToQuestions(String rawText,
      {String? taskId, bool isMarkdown = false}) async {
    return _textParseService.parseTextToQuestions(
      rawText,
      taskId: taskId,
      isMarkdown: isMarkdown,
    );
  }

  Future<List<Map<String, dynamic>>> parseMicroBatches(
      List<String> microBatches,
      {String? taskId,
      bool isMarkdown = false,
      String parseMode = 'all'}) async {
    return _textParseService.parseMicroBatches(
      microBatches,
      taskId: taskId,
      isMarkdown: isMarkdown,
      parseMode: QuestionParseMode.fromLegacyValue(parseMode),
    );
  }

  Future<Map<String, dynamic>> repairSingleQuestionRegion(
      TextQuestionRegion region) async {
    return _textParseService.repairSingleQuestionRegion(region);
  }

  Future<List<Map<String, dynamic>>> parseImagesWithVision(
    List<String> imagePaths, {
    bool repairLatex = false,
  }) async {
    return _visionParseService.parseImages(imagePaths,
        repairLatex: repairLatex);
  }

  Future<List<Map<String, dynamic>>> parseFileWithVision(
      String filePath) async {
    return _visionParseService.parseFile(filePath);
  }

  // 轻量级 AI 结构化二次配对 (用于跨文件合并，如题干文件 + 答案文件)
  Future<List<Map<String, dynamic>>> mergeStructuredQuestions(
      List<List<Map<String, dynamic>>> fileResults) async {
    return _questionMergeService.merge(fileResults);
  }
}
