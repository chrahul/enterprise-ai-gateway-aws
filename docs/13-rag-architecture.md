# RAG Architecture

## What Is RAG

Retrieval-Augmented Generation (RAG) is an architectural pattern that grounds language model responses in factual, organisation-specific knowledge. Instead of relying solely on what a model learned during pre-training (which has a knowledge cutoff and contains no proprietary data), RAG retrieves relevant content from a knowledge source at query time and injects it into the prompt.

Without RAG, asking a model "What is our current refund policy?" returns a hallucination or a refusal. With RAG, the system retrieves the actual policy document and the model summarises or reasons over it.

## Why RAG for Enterprise

| Problem | Without RAG | With RAG |
|---|---|---|
| Knowledge cutoff | Model cannot answer questions about events after training | Retrieval fetches current documents at query time |
| Proprietary knowledge | Model has no access to internal documentation | Retrieval fetches from internal knowledge base |
| Hallucination risk | Model invents plausible but incorrect answers | Answer is grounded in retrieved source documents |
| Auditability | Impossible to know what the model "knows" | Retrieved context is logged and auditable |
| Domain expertise | General-purpose model lacks domain depth | Domain documents injected into context |

## RAG Retrieval Workflow

```
                         Query
User ──────────────────────────────────▶ Application
                                              │
                                    1. Embed query
                                              │
                                              ▼
                                     Embedding Model
                                    (Bedrock Titan Text)
                                              │
                                    2. Search vector DB
                                              │
                                              ▼
                                       Vector Database
                                   (OpenSearch Serverless)
                                              │
                                    3. Return top-k chunks
                                              │
                                              ▼
                              Application assembles augmented prompt:
                              [System prompt] + [Retrieved chunks] + [Query]
                                              │
                                    4. Send to AI Gateway
                                              │
                                              ▼
                                    AI Gateway (LiteLLM)
                                              │
                                    5. Route to model
                                              │
                                              ▼
                                     Amazon Bedrock
                                  (Claude 3.5 Sonnet)
                                              │
                                    6. Return response
                                              │
                                              ▼
User ◀─────────────────────────────────── Application
```

## Components

### Embedding Model

The embedding model converts text (both documents and queries) into dense vector representations. Semantically similar text produces geometrically close vectors, enabling similarity search.

**Recommended:** Amazon Titan Text Embeddings V2 via Amazon Bedrock
- Model ID: `amazon.titan-embed-text-v2:0`
- Dimensions: 1024 (configurable to 256 or 512 for space efficiency)
- Same IRSA role used for generation models can be extended to embedding models
- No additional infrastructure required

```python
import boto3
import json

bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")

def embed_text(text: str) -> list[float]:
    response = bedrock.invoke_model(
        modelId="amazon.titan-embed-text-v2:0",
        body=json.dumps({
            "inputText": text,
            "dimensions": 1024,
            "normalize": True
        }),
        contentType="application/json",
        accept="application/json"
    )
    return json.loads(response["body"].read())["embedding"]
```

### Vector Database

The vector database stores document embeddings and provides approximate nearest-neighbour (ANN) search.

**Recommended for new deployments:** Amazon OpenSearch Serverless (vector engine)
- Fully managed, no cluster to provision
- Scales automatically to zero when idle
- Supports FAISS-based ANN with cosine similarity
- IAM authentication (same pattern as Bedrock)

**Alternative for existing PostgreSQL deployments:** pgvector extension on Amazon Aurora PostgreSQL
- Adds vector similarity search to an existing relational store
- Useful when knowledge data is already in relational form

### Document Pipeline

Documents must be preprocessed before they can be stored in the vector database:

```
Raw Documents (PDF, Word, HTML, Confluence, S3)
         │
    1. Parse (text extraction, OCR if needed)
         │
    2. Chunk (split into ~500-token segments with overlap)
         │
    3. Embed (Titan Text Embeddings V2)
         │
    4. Store (OpenSearch Serverless or pgvector)
```

Chunking strategy significantly affects retrieval quality:
- **Fixed-size chunking** — Simple; works for homogeneous text
- **Semantic chunking** — Split at paragraph/section boundaries; better for structured documents
- **Hierarchical chunking** — Store both summary and detail chunks; enables two-stage retrieval

## Enterprise Use Cases

### Internal Knowledge Base

Replace keyword-search-based internal wikis with conversational access to Confluence, SharePoint, or S3-hosted documentation. Employees ask questions in natural language; the system retrieves relevant pages and generates a synthesised answer with source citations.

### Compliance and Regulatory Documents

Compliance teams can query policy documents, regulatory filings, and audit reports. The gateway enforces that responses are grounded in approved documents. All retrieved chunks are logged (via Langfuse or CloudWatch) for audit purposes.

### Product Documentation and Support

Customer-facing support applications can use RAG to answer product questions based on the official documentation corpus. The model cannot answer questions that are not in the documentation (reducing hallucination risk), and responses can cite the source article.

### Code Repository Search

Embedding code at the function level enables semantic code search: "find all functions that validate JWT tokens" returns relevant code regardless of naming conventions.

## How the AI Gateway Relates to RAG

The AI Gateway sits in front of the generation model. The RAG retrieval step (embedding + vector search) happens outside the gateway, in the application layer. The gateway's role in a RAG system is:

1. **Provide the embedding endpoint** — Applications call `/v1/embeddings` through the gateway to create embeddings, using the same authentication and audit trail as generation requests.
2. **Provide the generation endpoint** — The augmented prompt (query + retrieved context) is sent to the gateway as a standard `/v1/chat/completions` request.
3. **Enforce governance** — Token budget controls, rate limiting, and authentication apply equally to RAG-augmented requests.
4. **Provide cost visibility** — RAG requests often have large context windows (retrieved chunks + query). Per-model token tracking in the gateway makes the cost of retrieval-augmented generation visible.

```
Application Layer                    AI Gateway Layer
─────────────────────────────────    ─────────────────────────────
Query ──▶ Embed ──▶ VectorSearch      POST /v1/embeddings ──▶ Bedrock Titan
                         │            POST /v1/chat/completions ──▶ Bedrock Claude
                         ▼
              Assemble augmented prompt
                         │
                         └──────────────▶ AI Gateway ──▶ Bedrock Claude
```

## Adding Embedding Support to the Gateway

To route embedding requests through the gateway, add an embedding model to `litellm/config.yaml`:

```yaml
model_list:
  # ... existing generation models ...

  - model_name: titan-embed
    litellm_params:
      model: bedrock/amazon.titan-embed-text-v2:0
      aws_region_name: us-east-1
```

Applications then call:

```bash
curl -X POST http://ai-gateway/v1/embeddings \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "titan-embed", "input": "What is the refund policy?"}'
```

## See Also

- [05-bedrock-integration.md](05-bedrock-integration.md) — Bedrock model configuration
- [14-agentic-ai.md](14-agentic-ai.md) — Agents that use RAG as a tool
- [10-multi-model-routing.md](10-multi-model-routing.md) — Routing embedding and generation to different models
- [12-cost-governance.md](12-cost-governance.md) — Token costs for large RAG context windows
