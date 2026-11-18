var m=Object.defineProperty;var p=(r,e)=>{for(var t in e)m(r,t,{get:e[t],enumerable:!0})};import*as c from"../../core/platform/platform.js";function f(){return!!c.HostRuntime.HOST_RUNTIME.getLocalStorage()?.getItem("debugAiCodeGenerationEnabled")}function l(...r){f()&&console.log(...r)}function h(r){let e=c.HostRuntime.HOST_RUNTIME.getLocalStorage();r?e?.setItem("debugAiCodeGenerationEnabled","true"):e?.removeItem("debugAiCodeGenerationEnabled")}globalThis.setDebugAiCodeGenerationEnabled=h;var g={};p(g,{AiCodeGeneration:()=>u,additionalContextForConsole:()=>C,basePreamble:()=>b});import*as o from"../../core/host/host.js";import*as n from"../../core/root/root.js";var b=`You are a highly skilled senior software engineer with deep expertise across multiple web technologies and programming languages, including JavaScript, TypeScript, HTML, and CSS.
Your role is to act as an expert pair programmer within the Chrome DevTools environment.

**Core Directives (Adhere to these strictly):**

1. **Language and Quality:**
    * Generate code that is modern, efficient, and idiomatic for the inferred language (e.g., modern JavaScript/ES6+, semantic HTML5, efficient CSS).
    * Where appropriate, include basic error handling (e.g., for API calls).
    * Determine the programming language from the user's prompt.

2.  **Output Format (Strict):**
    * **Return ONLY code blocks.** * Do NOT include any introductory text, explanations, or concluding remarks.
    * Do NOT provide step-by-step guides or descriptions of how the code works.
    * Inline comments within the code are permitted and encouraged for clarity.

3. **Handling Ambiguity:**
    * If the user's request is vague, unclear, or lacks sufficient detail to generate a functional solution, do NOT generate placeholder code.
    * Instead, output a single comment block asking for specific clarification on the desired task or logic.
    * Example output for vague input: // The request is unclear. Please specify the desired functionality or logic you need implemented.
`,C=`
You are operating within the execution environment of the Chrome DevTools Console.
The console has direct access to the inspected page's \`window\` and \`document\`.

*   **Utilize Console Utilities:** You have access to the Console Utilities API. You **should** use these helper functions and variables when they are the most direct way to accomplish the user's goal.
`,u=class r{#i=crypto.randomUUID();#t;#e;constructor(e){this.#t=e.aidaClient,this.#e=e.serverSideLoggingEnabled??!1,n.Runtime.hostConfig.devToolsGeminiRebranding?.enabled&&(this.#e=!1)}#n(e,t,d=o.AidaClient.AidaInferenceLanguage.JAVASCRIPT){let s=o.AidaClient.convertToUserTierEnum(this.#r);function a(i){return typeof i=="number"&&i>=0?i:void 0}return e=t+e+`
**Target Language:** `+d,{client:o.AidaClient.CLIENT_NAME,preamble:t,current_message:{parts:[{text:e}],role:o.AidaClient.Role.USER},use_case:o.AidaClient.UseCase.CODE_GENERATION,options:{temperature:a(this.#o.temperature),model_id:this.#o.modelId||void 0},metadata:{disable_user_content_logging:!(this.#e??!1),string_session_id:this.#i,user_tier:s,client_version:n.Runtime.getChromeVersion()}}}get#r(){return n.Runtime.hostConfig.devToolsAiCodeGeneration?.userTier}get#o(){let e=n.Runtime.hostConfig.devToolsAiCodeGeneration?.temperature,t=n.Runtime.hostConfig.devToolsAiCodeGeneration?.modelId;return{temperature:e,modelId:t}}registerUserImpression(e,t,d){let s=Math.floor(t/1e3),a=t%1e3,i=Math.floor(a*1e6);this.#t.registerClientEvent({corresponding_aida_rpc_global_id:e,disable_user_content_logging:!(this.#e??!1),generate_code_client_event:{user_impression:{sample:{sample_id:d},latency:{duration:{seconds:s,nanos:i}}}}}),l("Registered user impression with latency {seconds:",s,", nanos:",i,"}"),o.userMetrics.actionTaken(o.UserMetrics.Action.AiCodeGenerationSuggestionDisplayed)}registerUserAcceptance(e,t){this.#t.registerClientEvent({corresponding_aida_rpc_global_id:e,disable_user_content_logging:!(this.#e??!1),generate_code_client_event:{user_acceptance:{sample:{sample_id:t}}}}),l("Registered user acceptance"),o.userMetrics.actionTaken(o.UserMetrics.Action.AiCodeGenerationSuggestionAccepted)}async generateCode(e,t,d,s){let a=this.#n(e,t,d),i=await this.#t.generateCode(a,s);return l({request:a,response:i}),i}static isAiCodeGenerationAvailable(){return n.Runtime.hostConfig.devToolsAiCodeGeneration?.enabled??!1}static isAiCodeGenerationEnabled(e){if(!e.startsWith("en-"))return!1;let t=n.Runtime.hostConfig.aidaAvailability;return!t||t.blockedByGeo||t.blockedByAge||t.blockedByEnterprisePolicy?!1:!!(t.enabled&&r.isAiCodeGenerationAvailable())}};export{g as AiCodeGeneration,l as debugLog,f as isDebugMode};
//# sourceMappingURL=ai_code_generation.js.map
