# Parameterreferenz

Generiert mit `python transcribe.py config docs`. Quelle: `scripts/config.py`.

Vorrang: CLI (wo angeboten) → Prozessumgebung → explizite `--config`-Datei → Benutzer-`.env` → Default. Leere Werte sind nicht gesetzt. Das Arbeitsverzeichnis wird nicht durchsucht.

`TRANSCRIBE_CONFIG_DIR` und `TRANSCRIBE_BIN_DIR` wählen isolierte Laufzeitverzeichnisse; `TRANSCRIBE_CONFIG` entspricht `--config`. Diese Bootstrap-Pfade kommen ausschliesslich aus der Prozessumgebung.

| Parameter | Typ | Default | Bedeutung |
|---|---|---|---|
| `TRANSCRIBE_LLM_PROVIDER` | auto, azure, anthropic, none | `auto` | Provider for analysis; none delegates to the harness. |
| `AZURE_LLM_ENDPOINT` | url | `` | Azure resource base URL. |
| `AZURE_LLM_KEY` | Geheimnis | `` | Azure analysis API key. |
| `AZURE_LLM_API_VERSION` | text | `2024-10-21` |  |
| `AZURE_LLM_MODEL` | text | `gpt-6.1-sol` | Text deployment. |
| `AZURE_LLM_MODEL_VISION` | text | `` | Vision deployment; unset uses the text deployment. |
| `AZURE_LLM_MODEL_FAST` | text | `` | Triage deployment; unset uses the text deployment. |
| `AZURE_LLM_MAX_TOKENS` | int | `4096` | Default completion budget; stages may request their own budget. |
| `AZURE_LLM_TIMEOUT` | float | `300` |  |
| `AZURE_CLAUDE_URL` | url | `` |  |
| `AZURE_CLAUDE_KEY` | Geheimnis | `` |  |
| `AZURE_CLAUDE_MODEL` | text | `claude-opus-4-7` |  |
| `AZURE_TRANSCRIBE_DIARIZE_URL` | url | `` | Full Azure audio endpoint, including api-version. |
| `AZURE_TRANSCRIBE_DIARIZE_KEY` | Geheimnis | `` |  |
| `AZURE_TRANSCRIBE_CHUNK_SECONDS` | float | `600` |  |
| `AZURE_TRANSCRIBE_OVERLAP_SECONDS` | float | `20` |  |
| `AZURE_TRANSCRIBE_TIMEOUT` | float | `900` |  |
| `GROQ_API_KEY` | Geheimnis | `` |  |
| `OPENAI_API_KEY` | Geheimnis | `` |  |
| `HF_TOKEN` | Geheimnis | `` | Hugging Face token; model licence acceptance is also required. |
| `HUGGINGFACE_TOKEN` | Geheimnis | `` | Compatibility alias for HF_TOKEN. |
| `PYANNOTE_API_KEY` | Geheimnis | `` |  |
| `ASSEMBLYAI_API_KEY` | Geheimnis | `` |  |
| `ASSEMBLYAI_REGION` | us, eu | `us` |  |
| `TRANSCRIBE_CPU_BUDGET` | cpu | `50%` | Shared CPU budget; percentage, positive thread count or all. |
| `TRANSCRIBE_WHISPER_MODEL` | text | `large-v3-turbo` |  |
| `TRANSCRIBE_GPU_COMPUTE` | float16, float32, int8, int8_float16, int8_float32, auto | `float16` |  |
| `TRANSCRIBE_GPU_DUTY` | float | `1` |  |
| `TRANSCRIBE_OCR_ACCEL` | cpu, dml, cuda, auto | `auto` |  |
| `TRANSCRIBE_REDACT` | bool | `` | Unset keeps existing crop redaction (off on a new run); source images still reach the analysis model. |
| `TRANSCRIBE_LLM_WORKERS` | int | `2` | Maximum concurrent independent chapter calls. |
| `CONFLUENCE_URL` | url | `` |  |
| `CONFLUENCE_TOKEN` | Geheimnis | `` |  |
| `CONFLUENCE_VERIFY_TLS` | bool | `1` |  |
| `CONFLUENCE_CA_BUNDLE` | text | `` | Optional PEM CA bundle for an internal server. |
| `SETUP_COMPLETE` | bool | `false` | Managed installation marker; doctor remains authoritative. |
| `DIARIZE_DISMISSED` | bool | `false` |  |
