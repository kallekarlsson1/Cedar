import CLlama
import Foundation

/// Qwen3-Embedding-0.6B (Q8 GGUF) on llama.cpp with Metal.
/// One text per call, truncated to 512 tokens, last-token pooling, L2-normalized.
public final class EmbeddingModel {
    public static let dimension = 1024
    public static let maxTokens = 512
    public static let queryPrompt = "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:"

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private var batch: llama_batch
    private let specials: [llama_token]   // tokens the tokenizer adds around a text

    public init(path: String) throws {
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(path, mp) else { throw SQLError(description: "can't load model at \(path)") }
        var cp = llama_context_default_params()
        cp.n_ctx = 1024
        cp.n_batch = 1024
        cp.n_ubatch = 1024
        cp.n_seq_max = 1
        cp.embeddings = true
        cp.pooling_type = LLAMA_POOLING_TYPE_LAST
        guard let context = llama_init_from_model(model, cp) else {
            llama_model_free(model)
            throw SQLError(description: "can't start the model")
        }
        self.model = model
        self.context = context
        vocab = llama_model_get_vocab(model)
        batch = llama_batch_init(Int32(Self.maxTokens + 8), 0, 1)
        specials = Self.tokenize(vocab, "", special: true)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    private static func tokenize(_ vocab: OpaquePointer, _ text: String, special: Bool) -> [llama_token] {
        let utf8 = Array(text.utf8)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 16)
        let n = utf8.withUnsafeBufferPointer { buf in
            buf.withMemoryRebound(to: CChar.self) {
                llama_tokenize(vocab, $0.baseAddress, Int32(utf8.count), &tokens, Int32(tokens.count), special, true)
            }
        }
        return n >= 0 ? Array(tokens.prefix(Int(n))) : []
    }

    public func embedQuery(_ text: String) -> [Float]? { embed(Self.queryPrompt + text) }

    public func embed(_ text: String) -> [Float]? {
        var tokens = Self.tokenize(vocab, text, special: true)
        if tokens.count > Self.maxTokens {
            let plain = Self.tokenize(vocab, text, special: false)
            let eos = llama_vocab_eos(vocab), bos = llama_vocab_bos(vocab)
            tokens = Array(plain.prefix(Self.maxTokens - 1))
            if specials.first == bos, specials.count > 1 || specials.last != eos { tokens.insert(bos, at: 0) }
            if specials.last == eos { tokens.append(eos) }
        }
        guard !tokens.isEmpty else { return nil }
        llama_memory_clear(llama_get_memory(context), true)
        batch.n_tokens = Int32(tokens.count)
        for (i, token) in tokens.enumerated() {
            batch.token[i] = token
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = 1
        }
        guard llama_decode(context, batch) == 0, let out = llama_get_embeddings_seq(context, 0) else { return nil }
        var v = Array(UnsafeBufferPointer(start: out, count: Self.dimension))
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        if norm > 0 { for i in v.indices { v[i] /= norm } }
        return v
    }
}
