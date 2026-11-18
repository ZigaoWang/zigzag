var f;(function(t){t.CSS="css",t.ARIA="aria",t.Text="text",t.XPath="xpath",t.Pierce="pierce"})(f||(f={}));var i;(function(t){t.Change="change",t.Click="click",t.Close="close",t.CustomStep="customStep",t.DoubleClick="doubleClick",t.EmulateNetworkConditions="emulateNetworkConditions",t.Hover="hover",t.KeyDown="keyDown",t.KeyUp="keyUp",t.Navigate="navigate",t.Scroll="scroll",t.SetViewport="setViewport",t.WaitForElement="waitForElement",t.WaitForExpression="waitForExpression"})(i||(i={}));var g;(function(t){t.Navigation="navigation"})(g||(g={}));var ct=Object.freeze({__proto__:null,get AssertedEventType(){return g},get SelectorType(){return f},get StepType(){return i}});function ne(t){throw new Error(`Unknown step type: ${t.type}`)}var lt=new Set(["textarea","text","url","tel","search","password","number","email"]),re=new Set(["mouse","pen","touch"]),A=new Map([["primary","left"],["auxiliary","middle"],["secondary","right"],["back","back"],["forward","forward"]]);function c(t,e){return Object.prototype.hasOwnProperty.call(t,e)?t[e]!==void 0:!1}function C(t){return typeof t=="object"&&t!==null}function y(t){return typeof t=="string"}function L(t){return typeof t=="number"}function k(t){return Array.isArray(t)}function ye(t){return typeof t=="boolean"}function Se(t){return k(t)&&t.every(e=>Number.isInteger(e))}function be(t){return typeof t=="string"&&re.has(t)}function Ee(t){return typeof t=="string"&&A.has(t)}function ie(t){if(c(t,"target")&&y(t.target))return t.target}function ve(t){if(c(t,"frame")){if(Se(t.frame))return t.frame;throw new Error("Step `frame` is not an integer array")}}function m(t,e){if(c(t,e)){let n=t[e];if(L(n))return n}throw new Error(`Step.${e} is not a number`)}function B(t,e){if(c(t,e)){let n=t[e];if(ye(n))return n}throw new Error(`Step.${e} is not a boolean`)}function D(t,e){if(c(t,e))return m(t,e)}function $(t,e){if(c(t,e))return F(t,e)}function Le(t,e){if(c(t,e))return B(t,e)}function F(t,e){if(c(t,e)){let n=t[e];if(y(n))return n}throw new Error(`Step.${e} is not a string`)}function ae(t){if(!c(t,"selectors"))throw new Error("Step does not have required selectors");if(!k(t.selectors))throw new Error("Step selectors are not an array");if(t.selectors.length===0)throw new Error("Step does not have required selectors");return t.selectors.map(e=>{if(!y(e)&&!k(e))throw new Error("Selector is not an array or string");return k(e)?e.map(n=>{if(!y(n))throw new Error("Selector element is not a string");return n}):e})}function ke(t){if(c(t,"selectors"))return ae(t)}function Ae(t){if(!C(t))throw new Error("Asserted event is not an object");if(!c(t,"type"))throw new Error("Asserted event is missing type");if(t.type===g.Navigation)return{type:g.Navigation,url:$(t,"url"),title:$(t,"title")};throw new Error("Unknown assertedEvent type")}function Fe(t){if(k(t))return t.map(Ae)}function Ce(t,e){if(c(e,"timeout")&&L(e.timeout)&&!ue(e.timeout))throw new Error(le);return{type:t,assertedEvents:c(e,"assertedEvents")?Fe(e.assertedEvents):void 0,timeout:c(e,"timeout")&&L(e.timeout)?e.timeout:void 0}}function b(t,e){return{...Ce(t,e),target:ie(e)}}function O(t,e){return{...b(t,e),frame:ve(e)}}function I(t,e){return{...O(t,e),selectors:ae(e)}}function oe(t){let e={offsetX:m(t,"offsetX"),offsetY:m(t,"offsetY"),duration:D(t,"duration")},n=$(t,"deviceType");if(n){if(!be(n))throw new Error(`'deviceType' for click steps must be one of the following: ${[...re].join(", ")}`);e.deviceType=n}let r=$(t,"button");if(r){if(!Ee(r))throw new Error(`'button' for click steps must be one of the following: ${[...A.keys()].join(", ")}`);e.button=r}return e}function $e(t){return{...I(i.Click,t),...oe(t),type:i.Click}}function Te(t){return{...I(i.DoubleClick,t),...oe(t),type:i.DoubleClick}}function xe(t){return{...I(i.Hover,t),type:i.Hover}}function Ne(t){return{...I(i.Change,t),type:i.Change,value:F(t,"value")}}function Ie(t){return{...b(i.KeyDown,t),type:i.KeyDown,key:F(t,"key")}}function Pe(t){return{...b(i.KeyUp,t),type:i.KeyUp,key:F(t,"key")}}function Be(t){return{...b(i.EmulateNetworkConditions,t),type:i.EmulateNetworkConditions,download:m(t,"download"),upload:m(t,"upload"),latency:m(t,"latency")}}function De(t){return{...b(i.Close,t),type:i.Close}}function He(t){return{...b(i.SetViewport,t),type:i.SetViewport,width:m(t,"width"),height:m(t,"height"),deviceScaleFactor:m(t,"deviceScaleFactor"),isMobile:B(t,"isMobile"),hasTouch:B(t,"hasTouch"),isLandscape:B(t,"isLandscape")}}function We(t){return{...O(i.Scroll,t),type:i.Scroll,x:D(t,"x"),y:D(t,"y"),selectors:ke(t)}}function Oe(t){return{...b(i.Navigate,t),type:i.Navigate,target:ie(t),url:F(t,"url")}}function Me(t){let e=$(t,"operator");if(e&&e!==">="&&e!=="=="&&e!=="<=")throw new Error("WaitForElement step's operator is not one of '>=','==','<='");if(c(t,"attributes")&&(!C(t.attributes)||Object.values(t.attributes).some(n=>typeof n!="string")))throw new Error("WaitForElement step's attribute is not a dictionary of strings");if(c(t,"properties")&&!C(t.properties))throw new Error("WaitForElement step's attribute is not an object");return{...I(i.WaitForElement,t),type:i.WaitForElement,operator:e,count:D(t,"count"),visible:Le(t,"visible"),attributes:c(t,"attributes")?t.attributes:void 0,properties:c(t,"properties")?t.properties:void 0}}function Re(t){if(!c(t,"expression"))throw new Error("waitForExpression step is missing `expression`");return{...O(i.WaitForExpression,t),type:i.WaitForExpression,expression:F(t,"expression")}}function je(t){if(!c(t,"name"))throw new Error("customStep is missing name");if(!y(t.name))throw new Error("customStep's name is not a string");return{...O(i.CustomStep,t),type:i.CustomStep,name:t.name,parameters:c(t,"parameters")?t.parameters:void 0}}function Ke(t,e){if(!C(t))throw new Error(e?`Step ${e} is not an object`:"Step is not an object");if(!c(t,"type"))throw new Error(e?`Step ${e} does not have a type`:"Step does not have a type");if(!y(t.type))throw new Error(e?`Type of the step ${e} is not a string`:"Type of the step is not a string");switch(t.type){case i.Click:return $e(t);case i.DoubleClick:return Te(t);case i.Hover:return xe(t);case i.Change:return Ne(t);case i.KeyDown:return Ie(t);case i.KeyUp:return Pe(t);case i.EmulateNetworkConditions:return Be(t);case i.Close:return De(t);case i.SetViewport:return He(t);case i.Scroll:return We(t);case i.Navigate:return Oe(t);case i.CustomStep:return je(t);case i.WaitForElement:return Me(t);case i.WaitForExpression:return Re(t);default:throw new Error(`Step type ${t.type} is not supported`)}}function Ue(t){let e=[];if(!k(t))throw new Error("Recording `steps` is not an array");for(let[n,r]of t.entries())e.push(Ke(r,n));return e}function Ve(t){return JSON.parse(JSON.stringify(t))}var se=1,ce=3e4,le=`Timeout is not between ${se} and ${ce} milliseconds`;function ue(t){return t>=se&&t<=ce}function ut(t){if(!C(t))throw new Error("Recording is not an object");if(!c(t,"title"))throw new Error("Recording is missing `title`");if(!y(t.title))throw new Error("Recording `title` is not a string");if(c(t,"timeout")&&!L(t.timeout))throw new Error("Recording `timeout` is not a number");if(!c(t,"steps"))throw new Error("Recording is missing `steps`");if(c(t,"timeout")&&L(t.timeout)&&!ue(t.timeout))throw new Error(le);return Ve({title:t.title,timeout:c(t,"timeout")&&L(t.timeout)?t.timeout:void 0,selectorAttribute:c(t,"selectorAttribute")&&y(t.selectorAttribute)?t.selectorAttribute:void 0,steps:Ue(t.steps)})}function _e(t){for(let e of Object.values(f))if(t.startsWith(`${e}/`))return e;return f.CSS}function v(t){Array.isArray(t)||(t=[t]);function e(r){return r.replace(/['"()]/g,"\\$&")}return t.map(r=>{switch(_e(r)){case f.ARIA:return`::-p-aria(${e(r.substring(f.ARIA.length+1))})`;case f.CSS:return r;case f.XPath:return`::-p-xpath(${e(r.substring(f.XPath.length+1))})`;case f.Pierce:return`:scope >>> ${r.substring(f.Pierce.length+1)}`;case f.Text:return`::-p-text(${e(r.substring(f.Text.length+1))})`}}).join(" >>>> ")}var T=class{async beforeAllSteps(e,n){}async afterAllSteps(e,n){}async beforeEachStep(e,n,r){}async stringifyStep(e,n,r){}async afterEachStep(e,n,r){}};var J=class extends T{async beforeAllSteps(e,n){let r={...n,steps:void 0},o=JSON.stringify(r,null,e.getIndent()).split(`
`);o.pop(),o[o.length-1]+=",",o.push(e.getIndent()+'"steps": ['),e.appendLine(o.join(`
`)).startBlock().startBlock()}async afterAllSteps(e){e.endBlock().endBlock().appendLine(e.getIndent()+"]").appendLine("}")}async stringifyStep(e,n,r){let a=JSON.stringify(n,null,e.getIndent());if(!r){e.appendLine(a);return}let o=r.steps.lastIndexOf(n)===r.steps.length-1?"":",";e.appendLine(a+o)}};var H=class{#e;#t=0;#n=[];constructor(e){this.#e=e}appendLine(e){let n=e.split(`
`).map(r=>r?this.#e.repeat(this.#t)+r.trimEnd():"");return this.#n.push(...n),this}startBlock(){return this.#t++,this}endBlock(){if(this.#t--,this.#t<0)throw new Error("Extra endBlock");return this}toString(){return this.#n.join(`
`)+`
`}getIndent(){return this.#e}getSize(){return this.#n.length}};function d(t,e){let n=[];return j(t,n,1,e),n.join("")}function j(t,e=[],n=1,r="  "){switch(typeof t){case"bigint":case"symbol":case"function":case"undefined":throw new Error("Invalid JSON");case"number":case"boolean":e.push(String(t));break;case"string":e.push(qe(t));break;case"object":{if(t===null)e.push("null");else if(Array.isArray(t)){e.push(`[
`);for(let a=0;a<t.length;a++)e.push(r.repeat(n)),j(t[a],e,n+1,r),a!==t.length-1&&e.push(","),e.push(`
`);e.push(r.repeat(n-1)+"]")}else{e.push(`{
`);let a=Object.keys(t);for(let o=0;o<a.length;o++){let u=a[o],s=t[u];s!==void 0&&(e.push(r.repeat(n)),e.push(u),e.push(": "),j(s,e,n+1,r),o!==a.length-1&&e.push(","),e.push(`
`))}e.push(r.repeat(n-1)+"}")}break}default:throw new Error("Unknown object type")}return e}var Y=(t,e)=>t.toString(16).toUpperCase().padStart(e,"0"),R=new Map([["\b","\\b"],["\f","\\f"],[`
`,"\\n"],["\r","\\r"],["	","\\t"],["\v","\\v"],["'","\\'"],["\\","\\\\"],["<!--","\\x3C!--"],["<script","\\x3Cscript"],["<\/script","\\x3C/script"]]),qe=t=>{let e=/(\\|<(?:!--|\/?script))|(\p{Control})|(\p{Surrogate})/gu,n=/(\\|'|<(?:!--|\/?script))|(\p{Control})|(\p{Surrogate})/gu,r=(u,s,p,l)=>p?R.has(p)?R.get(p):"\\x"+Y(p.charCodeAt(0),2):l?"\\u"+Y(l.charCodeAt(0),4):s?R.get(s)||"":u,a="",o="";return t.includes("'")?t.includes('"')?!t.includes("`")&&!t.includes("${")?(o="`",a=t.replace(e,r)):(o="'",a=t.replace(n,r)):(o='"',a=t.replace(e,r)):(o="'",a=t.replace(e,r)),`${o}${a}${o}`};var x=class extends T{#e=!1;#t;constructor(e="chrome"){super(),this.#t=e}async beforeAllSteps(e,n){e.appendLine("import { Locator, launch } from 'puppeteer'; // v25.0.0 or later"),e.appendLine(""),this.#t==="firefox"?e.appendLine("const browser = await launch({browser: 'firefox'});"):e.appendLine("const browser = await launch();"),e.appendLine("const page = await browser.newPage();"),e.appendLine(`const timeout = ${n.timeout||Xe};`),e.appendLine("page.setDefaultTimeout(timeout);"),e.appendLine(""),this.#e=!1}async afterAllSteps(e,n){if(e.appendLine(""),e.appendLine("await browser.close();"),e.appendLine(""),this.#e)for(let r of Je.split(`
`))e.appendLine(r)}async stringifyStep(e,n,r){e.appendLine("{").startBlock(),n.timeout!==void 0&&e.appendLine(`const timeout = ${n.timeout};`),this.#a(e,n);let a=n.assertedEvents&&n.type!==i.Navigate;if(a){e.appendLine("const promises = [];"),e.appendLine("const startWaitingForEvents = () => {").startBlock();for(let o of n.assertedEvents)if(o.type===g.Navigation)e.appendLine(`promises.push(${"frame"in n&&n.frame?"frame":"targetPage"}.waitForNavigation());`);else throw new Error(`Event type ${o.type} is not supported`);e.endBlock().appendLine("}")}this.#m(e,n),a&&e.appendLine("await Promise.all(promises);"),e.endBlock().appendLine("}")}#n(e,n){n==="main"?e.appendLine("const targetPage = page;"):(e.appendLine(`const target = await browser.waitForTarget(t => t.url() === ${d(n,e.getIndent())}, { timeout });`),e.appendLine("const targetPage = await target.page();"),e.appendLine("targetPage.setDefaultTimeout(timeout);"))}#i(e,n){e.appendLine("let frame = targetPage.mainFrame();");for(let r of n)e.appendLine(`frame = frame.childFrames()[${r}];`)}#a(e,n){this.#n(e,n.target||"main"),n.frame&&this.#i(e,n.frame)}#r(e,n,r){e.appendLine("await Locator.race([").startBlock(),e.appendLine(n.selectors.map(a=>`${n.frame?"frame":"targetPage"}.locator(${d(v(a),e.getIndent())})`).join(`,
`)),e.endBlock().appendLine("])"),e.startBlock().appendLine(".setTimeout(timeout)"),n.assertedEvents?.length&&e.appendLine(".on('action', () => startWaitingForEvents())"),r(),e.endBlock()}#o(e,n){this.#r(e,n,()=>{e.appendLine(".click({"),n.duration&&e.appendLine(`  delay: ${n.duration},`),n.button&&e.appendLine(`  button: '${A.get(n.button)}',`),e.appendLine("  offset: {"),e.appendLine(`    x: ${n.offsetX},`),e.appendLine(`    y: ${n.offsetY},`),e.appendLine("  },"),e.appendLine("});")})}#s(e,n){this.#r(e,n,()=>{e.appendLine(".click({"),e.appendLine("  count: 2,"),n.duration&&e.appendLine(`  delay: ${n.duration},`),n.button&&e.appendLine(`  button: '${A.get(n.button)}',`),e.appendLine("  offset: {"),e.appendLine(`    x: ${n.offsetX},`),e.appendLine(`    y: ${n.offsetY},`),e.appendLine("  },"),e.appendLine("});")})}#c(e,n){this.#r(e,n,()=>{e.appendLine(".hover();")})}#l(e,n){this.#r(e,n,()=>{e.appendLine(`.fill(${d(n.value,e.getIndent())});`)})}#u(e,n){e.appendLine("await targetPage.emulateNetworkConditions({"),e.appendLine(`  offline: ${!n.download&&!n.upload},`),e.appendLine(`  downloadThroughput: ${n.download},`),e.appendLine(`  uploadThroughput: ${n.upload},`),e.appendLine(`  latency: ${n.latency},`),e.appendLine("});")}#p(e,n){e.appendLine(`await targetPage.keyboard.down(${d(n.key,e.getIndent())});`)}#f(e,n){e.appendLine(`await targetPage.keyboard.up(${d(n.key,e.getIndent())});`)}#d(e,n){e.appendLine("await targetPage.close()")}#w(e,n){e.appendLine(`await targetPage.setViewport(${d({width:n.width,height:n.height},e.getIndent())})`)}#h(e,n){"selectors"in n?this.#r(e,n,()=>{e.appendLine(`.scroll({ scrollTop: ${n.y}, scrollLeft: ${n.x}});`)}):e.appendLine(`await targetPage.evaluate((x, y) => { window.scroll(x, y); }, ${n.x}, ${n.y})`)}#m(e,n){switch(n.type){case i.Click:return this.#o(e,n);case i.DoubleClick:return this.#s(e,n);case i.Hover:return this.#c(e,n);case i.Change:return this.#l(e,n);case i.EmulateNetworkConditions:return this.#u(e,n);case i.KeyDown:return this.#p(e,n);case i.KeyUp:return this.#f(e,n);case i.Close:return this.#d(e,n);case i.SetViewport:return this.#w(e,n);case i.Scroll:return this.#h(e,n);case i.Navigate:return this.#g(e,n);case i.WaitForElement:return this.#S(e,n);case i.WaitForExpression:return this.#y(e,n);case i.CustomStep:return;default:return ne(n)}}#g(e,n){e.appendLine(`await targetPage.goto(${d(n.url,e.getIndent())});`)}#y(e,n){e.appendLine(`await ${n.frame?"frame":"targetPage"}.waitForFunction(${d(n.expression,e.getIndent())}, { timeout });`)}#S(e,n){this.#e=!0,e.appendLine(`await waitForElement(${d(n,e.getIndent())}, ${n.frame?"frame":"targetPage"}, timeout);`)}},Xe=5e3,Je=`async function waitForElement(step, frame, timeout) {
  const {
    count = 1,
    operator = '>=',
    visible = true,
    properties,
    attributes,
  } = step;
  const compFn = {
    '==': (a, b) => a === b,
    '>=': (a, b) => a >= b,
    '<=': (a, b) => a <= b,
  }[operator];
  await waitForFunction(async () => {
    const elements = await querySelectorsAll(step.selectors, frame);
    let result = compFn(elements.length, count);
    const elementsHandle = await frame.evaluateHandle((...elements) => {
      return elements;
    }, ...elements);
    await Promise.all(elements.map((element) => element.dispose()));
    if (result && (properties || attributes)) {
      result = await elementsHandle.evaluate(
        (elements, properties, attributes) => {
          for (const element of elements) {
            if (attributes) {
              for (const [name, value] of Object.entries(attributes)) {
                if (element.getAttribute(name) !== value) {
                  return false;
                }
              }
            }
            if (properties) {
              if (!isDeepMatch(properties, element)) {
                return false;
              }
            }
          }
          return true;

          function isDeepMatch(a, b) {
            if (a === b) {
              return true;
            }
            if ((a && !b) || (!a && b)) {
              return false;
            }
            if (!(a instanceof Object) || !(b instanceof Object)) {
              return false;
            }
            for (const [key, value] of Object.entries(a)) {
              if (!isDeepMatch(value, b[key])) {
                return false;
              }
            }
            return true;
          }
        },
        properties,
        attributes
      );
    }
    await elementsHandle.dispose();
    return result === visible;
  }, timeout);
}

async function querySelectorsAll(selectors, frame) {
  for (const selector of selectors) {
    const result = await querySelectorAll(selector, frame);
    if (result.length) {
      return result;
    }
  }
  return [];
}

async function querySelectorAll(selector, frame) {
  if (!Array.isArray(selector)) {
    selector = [selector];
  }
  if (!selector.length) {
    throw new Error('Empty selector provided to querySelectorAll');
  }
  let elements = [];
  for (let i = 0; i < selector.length; i++) {
    const part = selector[i];
    if (i === 0) {
      elements = await frame.$$(part);
    } else {
      const tmpElements = elements;
      elements = [];
      for (const el of tmpElements) {
        elements.push(...(await el.$$(part)));
      }
    }
    if (elements.length === 0) {
      return [];
    }
    if (i < selector.length - 1) {
      const tmpElements = [];
      for (const el of elements) {
        const newEl = (await el.evaluateHandle(el => el.shadowRoot ? el.shadowRoot : el)).asElement();
        if (newEl) {
          tmpElements.push(newEl);
        }
      }
      elements = tmpElements;
    }
  }
  return elements;
}

async function waitForFunction(fn, timeout) {
  let isActive = true;
  const timeoutId = setTimeout(() => {
    isActive = false;
  }, timeout);
  while (isActive) {
    const result = await fn();
    if (result) {
      clearTimeout(timeoutId);
      return;
    }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  throw new Error('Timed out');
}`;var pe="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",Ye=pe.split("").reduce((t,e,n)=>(t.set(e,n),t),new Map),fe=31,de=32,z=2147483647;function ze(t){if(t<0)throw new Error("Only postive integers and zero are supported");if(t>z)throw new Error("Only integers between 0 and "+z+" are supported");let e=[];do{let n=t&fe;t>>>=5,t>0&&(n|=de),e.push(pe[n])}while(t!==0);return e.join("")}function Qe(t){let e=[];for(let n of t)e.push(ze(n));return e.join("")}function Ge(t){let e=[],n=t.split(""),r=0,a=0;for(let o of n){let u=Ye.get(o);r|=(u&fe)<<a,a+=5,u&de||(e.push(r),r=0,a=0)}return e}var V="//# recorderSourceMap=";async function pt(t,e){e||(e={});let n=e.extension??new x,r=e.writer??new H(e.indentation??"  ");await n.beforeAllSteps?.(r,t);let a=[1];for(let o of t.steps){let u=r.getSize();await n.beforeEachStep?.(r,o,t),await n.stringifyStep(r,o,t),await n.afterEachStep?.(r,o,t);let s=r.getSize();a.push(u,s-u)}return await n.afterAllSteps?.(r,t),r.appendLine(V+Qe(a)),r.toString()}async function ft(t,e){e||(e={});let n=e.extension;n||(n=new x),e.indentation||(e.indentation="  ");let r=e.writer??new H(e.indentation??"  ");return await n.beforeEachStep?.(r,t),await n.stringifyStep(r,t),await n.afterEachStep?.(r,t),r.toString()}function we(t){return t.trim().startsWith(V)}function dt(t){let e=t.split(`
`);for(let n=e.length-1;n>=0;n--){let r=e[n];if(we(r))return Ge(r.trim().substring(V.length))}}function wt(t){return t.split(`
`).filter(n=>!we(n)).join(`
`)}var N=class{async beforeAllSteps(e){}async afterAllSteps(e){}async beforeEachStep(e,n){}async runStep(e,n){}async afterEachStep(e,n){}},Ze={"==":(t,e)=>t===e,">=":(t,e)=>t>=e,"<=":(t,e)=>t<=e};function Q(t){return new Promise(e=>{setTimeout(e,t)})}var W=class extends N{browser;page;timeout;constructor(e,n,r){super(),this.browser=e,this.page=n,this.timeout=r?.timeout||5e3}async#e(e){try{await e._client().send("Emulation.setAutomationOverride",{enabled:!0})}catch{}}#t(e,n){return e.timeout||n?.timeout||this.timeout}async runStep(e,n){let r=this.#t(e,n),a=this.page,o=this.browser,u=await tt(o,a,e,r),s=null;!u&&e.target&&(s=await a.waitForFrame(e.target,{timeout:r}));let p=s||u;if(!p)throw new Error("Target is not found for step: "+JSON.stringify(e));await this.#e(p);let l=await et(p,e);await this.runStepInFrame(e,a,p,l,r)}async runStepInFrame(e,n,r,a,o){let u=null,s=()=>{u=nt(a,e,o)},p=this.page.locatorRace;switch(e.type){case i.DoubleClick:await p(e.selectors.map(l=>a.locator(v(l)))).setTimeout(o).on("action",()=>s()).click({count:2,button:e.button&&A.get(e.button),delay:e.duration,offset:{x:e.offsetX,y:e.offsetY}});break;case i.Click:await p(e.selectors.map(l=>a.locator(v(l)))).setTimeout(o).on("action",()=>s()).click({delay:e.duration,button:e.button&&A.get(e.button),offset:{x:e.offsetX,y:e.offsetY}});break;case i.Hover:await p(e.selectors.map(l=>a.locator(v(l)))).setTimeout(o).on("action",()=>s()).hover();break;case i.EmulateNetworkConditions:{s();let{download:l,upload:w,latency:P}=e;await n.emulateNetworkConditions({offline:!l&&!w,download:l,upload:w,latency:P})}break;case i.KeyDown:s(),await n.keyboard.down(e.key),await Q(100);break;case i.KeyUp:s(),await n.keyboard.up(e.key),await Q(100);break;case i.Close:"close"in r&&(s(),await r.close());break;case i.Change:await p(e.selectors.map(l=>a.locator(v(l)))).on("action",()=>s()).setTimeout(o).fill(e.value);break;case i.SetViewport:{"setViewport"in r&&(s(),await r.setViewport(e));break}case i.Scroll:{"selectors"in e?await p(e.selectors.map(l=>a.locator(v(l)))).on("action",()=>s()).setTimeout(o).scroll({scrollLeft:e.x||0,scrollTop:e.y||0}):(s(),await a.evaluate((l,w)=>{window.scroll(l,w)},e.x||0,e.y||0));break}case i.Navigate:{s(),await a.goto(e.url);break}case i.WaitForElement:{try{s(),await rt(e,a,o)}catch(l){throw l.message==="Timed out"?new Error("waitForElement timed out. The element(s) could not be found."):l}break}case i.WaitForExpression:{s(),await a.waitForFunction(e.expression,{timeout:o});break}case i.CustomStep:break;default:ne(e)}await u}},K=class extends W{async afterAllSteps(){await this.browser.close()}};async function et(t,e){let n="mainFrame"in t?t.mainFrame():t;if("frame"in e&&e.frame)for(let r of e.frame)n=n.childFrames()[r];return n}async function tt(t,e,n,r){if(!n.target||n.target==="main")return e;let o=await(await t.waitForTarget(u=>u.url()===n.target,{timeout:r})).page();return o?(o.setDefaultTimeout(r),o):null}async function nt(t,e,n){let r=[];if(e.assertedEvents)for(let a of e.assertedEvents)if(a.type===g.Navigation){r.push(t.waitForNavigation({timeout:n}));continue}else throw new Error(`Event type ${a.type} is not supported`);await Promise.all(r)}async function rt(t,e,n){let{count:r=1,operator:a=">=",visible:o=!0,properties:u,attributes:s}=t,p=Ze[a];await ot(async()=>{let l=await it(t.selectors,e),w=p(l.length,r),P=await e.evaluateHandle((...E)=>E,...l);return await Promise.all(l.map(E=>E.dispose())),w&&(u||s)&&(w=await P.evaluate((E,_,q)=>{if(q){for(let h of E)for(let[S,M]of Object.entries(q))if(h.getAttribute(S)!==M)return!1}if(_){for(let h of E)if(!X(_,h))return!1}return!0;function X(h,S){if(h===S)return!0;if(h&&!S||!h&&S||!(h instanceof Object)||!(S instanceof Object))return!1;for(let[M,ge]of Object.entries(h))if(!X(ge,S[M]))return!1;return!0}},u,s)),await P.dispose(),w===o},n)}async function it(t,e){for(let n of t){let r=await at(n,e);if(r.length)return r}return[]}async function at(t,e){if(Array.isArray(t)||(t=[t]),!t.length)throw new Error("Empty selector provided to querySelectorAll");let n=await e.$$(t[0]);if(!n.length)return[];for(let r of t.slice(1,t.length))if(n=(await Promise.all(n.map(async a=>{let o=await a.evaluateHandle(s=>s.shadowRoot?s.shadowRoot:s),u=await o.$$(r);return o.dispose(),a.dispose(),u}))).flat(),!n.length)return[];return n}async function ot(t,e){let n=!0,r=setTimeout(()=>{n=!1},e);for(;n;){if(await t()){clearTimeout(r);return}await new Promise(o=>setTimeout(o,100))}throw new Error("Timed out")}async function G(t,e,n){await t.beforeEachStep?.(e,n),await t.runStep(e,n),await t.afterEachStep?.(e,n)}var U=class{#e;#t;#n=!1;constructor(e){this.#t=e}abort(){this.#n=!0}set flow(e){this.#e=e}async runBeforeAllSteps(e){await this.#t.beforeAllSteps?.(e)}async runAfterAllSteps(e){await this.#t.afterAllSteps?.(e)}async runStep(e){await G(this.#t,e)}async run(){if(!this.#e)throw new Error("Set the flow on the runner instance before calling `run`.");let e=this.#e;if(this.#n=!1,await this.#t.beforeAllSteps?.(e),this.#n)return!1;for(let n of e.steps){if(this.#n)return await this.#t.afterAllSteps?.(e),!1;await G(this.#t,n,e)}return await this.#t.afterAllSteps?.(e),!0}};async function ht(t,e){let n=t instanceof N?t:e,r=t instanceof N?void 0:t,a=new U(n??await st());return r&&(a.flow=r),a}async function st(){let{default:t}=await import("puppeteer"),e=await t.launch(),n=await e.newPage();return new K(e,n)}var Z=class extends T{async beforeAllSteps(e){e.appendLine("import url from 'url';"),e.appendLine("import { createRunner } from '@puppeteer/replay';"),e.appendLine(""),e.appendLine("export async function run(extension) {").startBlock(),e.appendLine("const runner = await createRunner(extension);"),e.appendLine(""),e.appendLine("await runner.runBeforeAllSteps();"),e.appendLine("")}async afterAllSteps(e){e.appendLine(""),e.appendLine("await runner.runAfterAllSteps();").endBlock().appendLine("}"),e.appendLine(""),e.appendLine("if (process && import.meta.url === url.pathToFileURL(process.argv[1]).href) {").startBlock().appendLine("run()").endBlock().appendLine("}")}async stringifyStep(e,n){e.appendLine(`await runner.runStep(${d(n,e.getIndent())});`)}};function he(t){return!!(t.type===i.Navigate||t.assertedEvents?.some(e=>e.type===g.Navigation))}function me(t){for(let e of t.steps)if(e.type===i.SetViewport)return e.isMobile;return!1}var ee=class extends x{#e=!1;async beforeAllSteps(e,n){e.appendLine("import fs from 'fs';"),await super.beforeAllSteps(e,n),e.appendLine("const lhApi = await import('lighthouse'); // v10.0.0 or later");let r={screenEmulation:{disabled:!0}};e.appendLine(`const flags = ${d(r,e.getIndent())}`),me(n)?e.appendLine("const config = undefined;"):e.appendLine("const config = lhApi.desktopConfig;"),e.appendLine(`const lhFlow = await lhApi.startFlow(page, {name: ${d(n.title,e.getIndent())}, config, flags});`)}async stringifyStep(e,n,r){if(n.type===i.SetViewport){await super.stringifyStep(e,n,r);return}let a=he(n);a?(this.#e&&(e.appendLine("await lhFlow.endTimespan();"),this.#e=!1),e.appendLine("await lhFlow.startNavigation();")):this.#e||(e.appendLine("await lhFlow.startTimespan();"),this.#e=!0),await super.stringifyStep(e,n,r),a&&e.appendLine("await lhFlow.endNavigation();")}async afterAllSteps(e,n){this.#e&&e.appendLine("await lhFlow.endTimespan();"),e.appendLine("const lhFlowReport = await lhFlow.generateReport();"),e.appendLine("fs.writeFileSync(import.meta.dirname + '/flow.report.html', lhFlowReport)"),await super.afterAllSteps(e,n)}};var te=class extends W{#e=!1;#t=!1;#n;async createFlowResult(){if(!this.#n)throw new Error("Cannot get flow result before running the flow");return this.#n.createFlowResult()}async beforeAllSteps(e){await super.beforeAllSteps?.(e);let{startFlow:n,desktopConfig:r}=await import("lighthouse"),a;me(e)||(a=r),this.#n=await n(this.page,{config:a,flags:{screenEmulation:{disabled:!0}},name:e.title})}async beforeEachStep(e,n){await super.beforeEachStep?.(e,n),e.type!==i.SetViewport&&(he(e)?(this.#e&&(await this.#n.endTimespan(),this.#e=!1),await this.#n.startNavigation(),this.#t=!0):this.#e||(await this.#n.startTimespan(),this.#e=!0))}async afterEachStep(e,n){this.#t&&(await this.#n.endNavigation(),this.#t=!1),await super.afterEachStep?.(e,n)}async afterAllSteps(e){this.#e&&await this.#n.endTimespan(),await super.afterAllSteps?.(e)}};export{g as AssertedEventType,J as JSONStringifyExtension,te as LighthouseRunnerExtension,ee as LighthouseStringifyExtension,Z as PuppeteerReplayStringifyExtension,W as PuppeteerRunnerExtension,K as PuppeteerRunnerOwningBrowserExtension,x as PuppeteerStringifyExtension,U as Runner,N as RunnerExtension,ct as Schema,f as SelectorType,i as StepType,T as StringifyExtension,ne as assertAllStepTypesAreHandled,ht as createRunner,qe as formatAsJSLiteral,d as formatJSONAsJS,_e as getSelectorType,ce as maxTimeout,se as minTimeout,A as mouseButtonMap,ut as parse,dt as parseSourceMap,Ke as parseStep,re as pointerDeviceTypes,v as selectorToPElementSelector,pt as stringify,ft as stringifyStep,wt as stripSourceMap,lt as typeableInputTypes,ue as validTimeout};
/**
 * @license
 * Copyright 2022 Google LLC
 * SPDX-License-Identifier: Apache-2.0
 */
//# sourceMappingURL=puppeteer-replay.js.map
