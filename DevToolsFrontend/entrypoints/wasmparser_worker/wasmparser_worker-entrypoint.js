import*as e from"./wasmparser_worker.js";self.onmessage=s=>{s.data.method==="disassemble"&&self.postMessage(e.WasmParserWorker.dissambleWASM(s.data.params,a=>{self.postMessage(a)}))};self.postMessage("workerReady");
//# sourceMappingURL=wasmparser_worker-entrypoint.js.map
