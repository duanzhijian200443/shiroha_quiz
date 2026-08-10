# A0 Built-in Agent v0

1. Parsing AI configuration and Agent configuration are independent product contracts.
   Shiroha Agent owns independent temperature and reasoning-effort settings;
   changing Agent tuning must not change exam-parsing model configuration.
2. Exam parsing is OCR + text-model first; vision is an optional expensive fallback.
3. Agent uses native model capabilities first; OCR/vision supplementation exists only when the main model lacks the required capability or the user explicitly requests it.
