var C=Object.defineProperty;var b=(a,t)=>{for(var e in t)C(a,e,{get:t[e],enumerable:!0})};import*as p from"../../core/platform/platform.js";function h(){return!!p.HostRuntime.HOST_RUNTIME.getLocalStorage()?.getItem("debugAiCodeCompletionEnabled")}function u(...a){h()&&console.log(...a)}function A(a){let t=p.HostRuntime.HOST_RUNTIME.getLocalStorage();a?t?.setItem("debugAiCodeCompletionEnabled","true"):t?.removeItem("debugAiCodeCompletionEnabled")}globalThis.setDebugAiCodeCompletionEnabled=A;var f={};b(f,{AiCodeCompletion:()=>m,consoleAdditionalContextFileContent:()=>v});import*as n from"../../core/host/host.js";import*as s from"../../core/root/root.js";var v=`/**
 * This file describes the execution environment of the Chrome DevTools Console.
 * The code is JavaScript, but with special global functions and variables.
 * Top-level await is available.
 * The console has direct access to the inspected page's \`window\` and \`document\`.
 */

/**
 * @description Returns the value of the most recently evaluated expression.
 */
let $_;

/**
 * @description A reference to the most recently selected DOM element.
 * $0, $1, $2, $3, $4 can be used to reference the last five selected DOM elements.
 */
let $0;

/**
 * @description A query selector alias. $$('.my-class') is equivalent to document.querySelectorAll('.my-class').
 */
function $$(selector, startNode) {}

/**
 * @description An XPath selector. $x('//p') returns an array of all <p> elements.
 */
function $x(path, startNode) {}

function clear() {}

function copy(object) {}

/**
 * @description Selects and reveals the specified element in the Elements panel.
 */
function inspect(object) {}

function keys(object) {}

function values(object) {}

/**
 * @description When the specified function is called, the debugger is invoked.
 */
function debug(func) {}

/**
 * @description Stops the debugging of the specified function.
 */
function undebug(func) {}

/**
 * @description Logs a message to the console whenever the specified function is called,
 * along with the arguments passed to it.
 */
function monitor(func) {}

/**
 * @description Stops monitoring the specified function.
 */
function unmonitor(func) {}

/**
 * @description Logs all events dispatched to the specified object to the console.
 */
function monitorEvents(object, events) {}

/**
 * @description Returns an object containing all event listeners registered on the specified object.
 */
function getEventListeners(object) {}

/**
 * The global \`console\` object has several helpful methods
 */
const console = {
  log: (...args) => {},
  warn: (...args) => {},
  error: (...args) => {},
  info: (...args) => {},
  debug: (...args) => {},
  assert: (assertion, ...args) => {},
  dir: (object) => {}, // Displays an interactive property listing of an object.
  dirxml: (object) => {}, // Displays an XML/HTML representation of an object.
  table: (data, columns) => {}, // Displays tabular data as a table.
  group: (label) => {}, // Creates a new inline collapsible group.
  groupEnd: () => {},
  time: (label) => {}, // Starts a timer.
  timeEnd: (label) => {} // Stops a timer and logs the elapsed time.
};`,R=5,_=3,m=class a{#s;#i;#e;#t;#a;#r=crypto.randomUUID();#o;#n;constructor(t,e,o){this.#o=t.aidaClient,this.#n=t.serverSideLoggingEnabled??!1,this.#s=o??[],this.#a=e}#d(t,e,o=n.AidaClient.AidaInferenceLanguage.JAVASCRIPT,i){let d=n.AidaClient.convertToUserTierEnum(this.#u);function l(r){return typeof r=="number"&&r>=0?r:void 0}t=`
`+t;let c=i;return{client:n.AidaClient.CLIENT_NAME,prefix:t,suffix:e,options:{inference_language:o,temperature:l(this.#l.temperature),model_id:this.#l.modelId||void 0,stop_sequences:this.#s},metadata:{disable_user_content_logging:!(this.#n??!1),string_session_id:this.#r,user_tier:d,client_version:s.Runtime.getChromeVersion()},additional_files:c}}async#c(t){let e=this.#p(t);if(e)return{response:e,fromCache:!0};let o=await this.#o.completeCode(t);return o?(this.#m(t,o),{response:o,fromCache:!1}):{response:null,fromCache:!1}}get#u(){return s.Runtime.hostConfig.devToolsAiCodeCompletion?.userTier}get#l(){let t=s.Runtime.hostConfig.devToolsAiCodeCompletion?.temperature,e=s.Runtime.hostConfig.devToolsAiCodeCompletion?.modelId;return{temperature:t,modelId:e}}#p(t){if(!this.#e||this.#e.request.suffix!==t.suffix||JSON.stringify(this.#e.request.options)!==JSON.stringify(t.options))return null;let e=[];for(let o of this.#e.response.generatedSamples){let i=this.#e.request.prefix+o.generationString;i.startsWith(t.prefix)&&e.push({generationString:i.substring(t.prefix.length),sampleId:o.sampleId,score:o.score,attributionMetadata:o.attributionMetadata})}return e.length===0?null:{generatedSamples:e,metadata:this.#e.response.metadata}}#m(t,e){this.#e={request:t,response:e}}registerUserImpression(t,e,o){let i=Math.floor(e/1e3),d=e%1e3,l=Math.floor(d*1e6);this.#o.registerClientEvent({corresponding_aida_rpc_global_id:t,disable_user_content_logging:!(this.#n??!1),complete_code_client_event:{user_impression:{sample:{sample_id:o},latency:{duration:{seconds:i,nanos:l}}}}}),u("Registered user impression with latency {seconds:",i,", nanos:",l,"}"),n.userMetrics.actionTaken(n.UserMetrics.Action.AiCodeCompletionSuggestionDisplayed)}registerUserAcceptance(t,e){this.#o.registerClientEvent({corresponding_aida_rpc_global_id:t,disable_user_content_logging:!(this.#n??!1),complete_code_client_event:{user_acceptance:{sample:{sample_id:e}}}}),u("Registered user acceptance"),n.userMetrics.actionTaken(n.UserMetrics.Action.AiCodeCompletionSuggestionAccepted)}clearCachedRequest(){this.#e=void 0}async completeCode(t,e,o,i,d){let l=t+e;if(l.length<R)return{response:null,fromCache:!1};if(this.#t&&Math.abs(l.length-this.#t.length)<_)return{response:null,fromCache:!1};let c=this.#d(t,e,i,d),{response:r,fromCache:g}=await this.#c(c);return u("At cursor position",o,{request:c,response:r,fromCache:g}),!r||r.generatedSamples.length===0?(this.#t=l,{response:null,fromCache:!1}):(this.#t=void 0,{response:r,fromCache:g})}remove(){this.#i&&(clearTimeout(this.#i),this.#i=void 0),this.#a?.setAiAutoCompletion(null)}static isAiCodeCompletionAvailable(){return s.Runtime.hostConfig.devToolsAiCodeCompletion?.enabled??!1}static isAiCodeCompletionEnabled(t){if(!t.startsWith("en-"))return!1;let e=s.Runtime.hostConfig.aidaAvailability;return!e||e.blockedByGeo||e.blockedByAge||e.blockedByEnterprisePolicy?!1:!!(e.enabled&&a.isAiCodeCompletionAvailable())}static isAiCodeCompletionStylesAvailable(){return s.Runtime.hostConfig.devToolsAiCodeCompletionStyles?.enabled??!1}static isAiCodeCompletionStylesEnabled(t){if(!t.startsWith("en-"))return!1;let e=s.Runtime.hostConfig.aidaAvailability;return!e||e.blockedByGeo||e.blockedByAge||e.blockedByEnterprisePolicy?!1:!!(e.enabled&&a.isAiCodeCompletionStylesAvailable())}};export{f as AiCodeCompletion,u as debugLog,h as isDebugMode};
//# sourceMappingURL=ai_code_completion.js.map
