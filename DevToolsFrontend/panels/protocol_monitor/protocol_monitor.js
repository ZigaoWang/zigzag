var Se=Object.defineProperty;var X=(a,e)=>{for(var o in e)Se(a,o,{get:e[o],enumerable:!0})};var ie={};X(ie,{DEFAULT_VIEW:()=>se,Events:()=>ae,JSONEditor:()=>R,ParameterType:()=>oe,suggestionFilter:()=>re});import"../../ui/kit/kit.js";import"../../ui/components/menus/menus.js";import*as ee from"../../core/common/common.js";import*as L from"../../core/host/host.js";import*as W from"../../core/i18n/i18n.js";import*as I from"../../core/sdk/sdk.js";import*as O from"../../ui/components/buttons/buttons.js";import*as E from"../../ui/components/suggestion_input/suggestion_input.js";import*as K from"../../ui/legacy/legacy.js";import*as Ie from"../../ui/lit/lit.js";import*as M from"../../ui/visual_logging/visual_logging.js";import*as te from"../elements/components/components.js";var Z=`*{box-sizing:border-box;padding:0;margin:0;font-size:inherit}:host{display:flex;flex-direction:column;height:100%}.target-selector{max-width:var(--sys-size-21)}.warning-icon{margin-left:-18px;margin-right:var(--sys-size-3)}.row{flex-wrap:wrap}.row,
.row-icons{display:flex;flex-direction:row;color:var(--sys-color-token-property-special);font-family:var(--monospace-font-family);font-size:var(--monospace-font-size);align-items:center;line-height:18px;margin-top:3px}.separator{margin-right:0.5em;color:var(--sys-color-on-surface)}ul{padding-left:2em}.optional-parameter{color:var(--sys-color-token-attribute-value);--override-color-recorder-input:var(--sys-color-on-surface)}.undefined-parameter{color:var(--sys-color-state-disabled)}.wrapper{display:flex;flex-direction:column;height:100%;min-height:0}.editor-wrapper{padding-left:1em;overflow-x:hidden;flex-grow:1;padding-top:0.5em;min-height:1lh}.editor-wrapper::after{content:"";display:block;height:50px}.clear-button,
.add-button,
.delete-button{opacity:0%;transition:opacity 0.3s ease-in-out}.clear-button,
.delete-button{margin-left:5px}.row:focus-within .delete-button,
.row:focus-within .add-button,
.row:focus-within .clear-button,
.row:hover .delete-button,
.row:hover .add-button,
.row:hover .clear-button{opacity:100%}.protocol-monitor-sidebar-toolbar{border-top:var(--sys-size-1) solid var(--sys-color-divider)}
/*# sourceURL=${import.meta.resolve("./JSONEditor.css")} */`;var{html:m,render:Ee,Directives:Re,nothing:u}=Ie,{live:P,classMap:j,repeat:Me}=Re,g={deleteParameter:"Delete parameter",addParameter:"Add parameter",resetDefaultValue:"Reset to default value",addCustomProperty:"Add custom property",sendCommandCtrlEnter:"Send command - Ctrl+Enter",sendCommandCmdEnter:"Send command - \u2318+Enter",copyCommand:"Copy command",selectTarget:"Select target"},Be=W.i18n.registerUIStrings("panels/protocol_monitor/JSONEditor.ts",g),y=W.i18n.getLocalizedString.bind(void 0,Be),oe=(s=>(s.STRING="string",s.NUMBER="number",s.BOOLEAN="boolean",s.ARRAY="array",s.OBJECT="object",s.UNKNOWN="unknown",s))(oe||{}),xe=a=>{if(a.length>150){let[e,o]=a.split(".");return e+"",[e,o]}return[a,""]},b=new Map([["string",""],["number",0],["boolean",!1],["unknown",""]]),S="dummy",U="<empty_string>";function re(a,e){return a.toLowerCase().includes(e.toLowerCase())}var ae=(e=>(e.SUBMIT_EDITOR="submiteditor",e))(ae||{}),Ne=ee.ObjectWrapper.eventMixin(K.Widget.VBox),R=class extends Ne{#t=new Map;#e=new Map;#a=new Map;#i=[];#r=[];#l="";#n;#o;#m;displayTargetSelector=!0;displayCommandInput=!0;displayToolbar=!0;constructor(e,o=se){super(e,{useShadowDom:!0}),this.#m=o,this.registerRequiredCSS(Z)}get metadataByCommand(){return this.#t}set metadataByCommand(e){this.#t=e,this.requestUpdate()}get typesByName(){return this.#e}set typesByName(e){this.#e=e,this.requestUpdate()}get enumsByName(){return this.#a}set enumsByName(e){this.#a=e,this.requestUpdate()}get parameters(){return this.#i}set parameters(e){this.#i=e,this.requestUpdate()}get targets(){return this.#r}set targets(e){this.#r=e,this.requestUpdate()}get command(){return this.#l}set command(e){this.#l!==e&&(this.#l=e,this.requestUpdate())}set commandToDisplay(e){this.displayCommand(e.command,e.parameters??{})}get targetId(){return this.#n}set targetId(e){this.#n!==e&&(this.#n=e,this.requestUpdate())}wasShown(){super.wasShown(),this.#o=new K.PopoverHelper.PopoverHelper(this.contentElement,o=>this.#C(o),"protocol-monitor.hint"),this.#o.setDisableOnClick(!0),this.#o.setTimeout(300),I.TargetManager.TargetManager.instance().addEventListener(I.TargetManager.Events.AVAILABLE_TARGETS_CHANGED,this.#s,this),this.#s(),this.requestUpdate()}willHide(){super.willHide(),this.#o?.hidePopover(),this.#o?.dispose(),I.TargetManager.TargetManager.instance().removeEventListener(I.TargetManager.Events.AVAILABLE_TARGETS_CHANGED,this.#s,this)}#s(){this.targets=I.TargetManager.TargetManager.instance().targets(),this.targets.length&&this.targetId===void 0&&(this.targetId=this.targets[0].id())}getParameters(){let e=t=>{if(t.value!==void 0)switch(t.type){case"number":return Number(t.value);case"boolean":return typeof t.value=="boolean"?t.value:String(t.value).trim().toLowerCase()==="true";case"object":{let n={};for(let r of t.value)e(r)!==void 0&&(n[r.name]=e(r));return Object.keys(n).length===0?void 0:n}case"array":{let n=[];for(let r of t.value)n.push(e(r));return n.length===0?[]:n}case"unknown":try{return JSON.parse(t.value)}catch{return t.value}default:return t.value}},o={};for(let t of this.parameters)o[t.name]=e(t);return e({type:"object",name:S,optional:!0,value:this.parameters,description:""})}displayCommand(e,o,t){this.targetId=t,this.command=e;let n=this.metadataByCommand.get(this.command);if(!n?.parameters)return;this.populateParametersForCommandWithDefaultValues();let r=this.#d("",o,{typeRef:S,type:"object",name:"",description:"",optional:!0,value:[]},n.parameters).value,s=new Map(this.parameters.map(l=>[l.name,l]));for(let l of r){let c=s.get(l.name);c&&(c.value=l.value)}this.requestUpdate()}#d(e,o,t,n){let r=t?.type||typeof o,s=t?.description??"",l=t?.optional??!0;switch(r){case"string":case"boolean":case"number":return this.#u(e,o,t);case"object":return this.#g(e,o,t,n);case"array":return this.#h(e,o,t)}return{type:r,name:e,optional:l,typeRef:t?.typeRef,value:o,description:s}}#u(e,o,t){let n=t?.type||typeof o,r=t?.description??"",s=t?.optional??!0;return{type:n,name:e,optional:s,typeRef:t?.typeRef,value:o,description:r,isCorrectType:t?this.#f(t,String(o)):!0}}#g(e,o,t,n){let r=t?.description??"";if(typeof o!="object"||o===null)throw new Error("The value is not an object");let s=t?.typeRef;if(!s)throw new Error("Every object parameters should have a type ref");let l=s===S?n:this.typesByName.get(s);if(!l)throw new Error("No nested type for keys were found");let c=[];for(let p of Object.keys(o)){let v=l.find(F=>F.name===p);c.push(this.#d(p,o[p],v))}return{type:"object",name:e,optional:t.optional,typeRef:t.typeRef,value:c,description:r,isCorrectType:!0}}#h(e,o,t){let n=t?.description??"",r=t?.optional??!0,s=t?.typeRef;if(!s)throw new Error("Every array parameters should have a type ref");if(!Array.isArray(o))throw new Error("The value is not an array");let l=H(s)?void 0:{optional:!0,type:"object",value:[],typeRef:s,description:"",name:""},c=[];for(let p=0;p<o.length;p++){let v=this.#d(`${p}`,o[p],l);c.push(v)}return{type:"array",name:e,optional:r,typeRef:t?.typeRef,value:c,description:n,isCorrectType:!0}}#C(e){let o=e.composedPath()[0],t=this.#$(o);if(!t?.description)return null;let[n,r]=xe(t.description),s=t.type,l=t.replyArgs,c;return l&&l.length>0?c=m`${r}Returns: ${l}<br>`:s?c=m`${r}<br>Type: ${s}<br>`:c=r,{box:o.boxInWindow(),show:async p=>{let v=new te.CSSHintDetailsView.CSSHintDetailsView({getMessage:()=>m`<span>${n}</span>`,getPossibleFixMessage:()=>c,getLearnMoreLink:()=>`https://chromedevtools.github.io/devtools-protocol/tot/${this.command.split(".")[0]}/`});return p.contentElement.appendChild(v),!0}}}#$(e){if(e.matches(".command")){let o=this.metadataByCommand.get(this.command);if(o)return{description:o.description,replyArgs:o.replyArgs}}if(e.matches(".parameter")){let o=e.dataset.paramid;if(!o)return;let t=o.split("."),{parameter:n}=this.#c(t);return n.description?{description:n.description,type:n.type}:void 0}}getCommandJson(){return this.command!==""?JSON.stringify({command:this.command,parameters:this.getParameters()}):""}#S(){let e=this.getCommandJson();L.InspectorFrontendHost.InspectorFrontendHostInstance.copyText(e)}#v(){this.dispatchEventToListeners("submiteditor",{command:this.command,parameters:this.getParameters(),targetId:this.targetId})}populateParametersForCommandWithDefaultValues(){let e=this.metadataByCommand.get(this.command)?.parameters;e&&(this.parameters=e.map(o=>this.#p(o)))}#p(e){if(e.type==="object"){let o=e.typeRef;o||(o=S);let n=(this.typesByName.get(o)??[]).map(r=>this.#p(r));return{...e,value:e.optional?void 0:n,isCorrectType:!0}}return e.type==="array"?{...e,value:e?.optional?void 0:e.value?.map(o=>this.#p(o))||[],isCorrectType:!0}:{...e,value:e.optional?void 0:b.get(e.type),isCorrectType:!0}}#c(e){let o=this.parameters,t;for(let n=0;n<e.length;n++){let r=e[n],s=o.find(l=>l.name===r);if(n===e.length-1)return{parameter:s,parentParameter:t};if(s?.type==="array"||s?.type==="object")s.value&&(o=s.value);else throw new Error("Parameter on the path in not an object or an array");t=s}throw new Error("Not found")}#f(e,o){if(e.type==="number"&&isNaN(Number(o)))return!1;let t=this.#w(e);return!(t.length!==0&&!t.includes(o))}#b=e=>{if(!(e.target instanceof E.SuggestionInput.SuggestionInput))return;let o;if(e instanceof KeyboardEvent){let s=e.target.renderRoot.querySelector("devtools-editable-content");if(!s)return;o=s.innerText}else o=e.target.value;let t=e.target.getAttribute("data-paramid");if(!t)return;let n=t.split("."),r=this.#c(n).parameter;if(o==="")r.value=b.get(r.type),r.isCorrectType=!0;else{let s=r.type==="boolean"?o.trim().toLowerCase():o;r.isCorrectType=this.#f(r,s),r.type==="boolean"&&r.isCorrectType?r.value=s==="true":r.value=o}this.requestUpdate()};#I=e=>{if(!(e.target instanceof E.SuggestionInput.SuggestionInput))return;let o=e.target.value,t=e.target.getAttribute("data-paramid");if(!t)return;let n=t.split("."),{parameter:r}=this.#c(n);r.name=o,this.requestUpdate()};#T=e=>{e.target instanceof E.SuggestionInput.SuggestionInput&&e.key==="Enter"&&(e.ctrlKey||e.metaKey)&&this.#b(e)};#E(e){if(!(e.target instanceof E.SuggestionInput.SuggestionInput))return;let o=e.target.getAttribute("data-paramid");if(!o)return;let t=o.split("."),n=this.#c(t).parameter;n.isCorrectType=!0,this.requestUpdate()}#R=async e=>{e.target instanceof E.SuggestionInput.SuggestionInput&&(this.command=e.target.value),this.populateParametersForCommandWithDefaultValues();let o=e.target;await this.updateComplete,this.#M(o)};#M(e){let o=this.contentElement.querySelectorAll("devtools-suggestion-input,.add-button"),t=[...o].findIndex(n=>n===e.shadowRoot?.host);t>=0&&t+1<o.length?o[t+1].focus():this.contentElement.querySelector('devtools-button[jslogcontext="protocol-monitor.send-command"]')?.focus()}#y(e,o){if(e.type==="object"){let t=e.typeRef;t||(t=S);let r=(this.typesByName.get(t)??[]).map(s=>this.#y(s,s.name));return{type:"object",name:o,optional:e.optional,typeRef:t,value:r,isCorrectType:!0,description:e.description}}return{type:e.type,name:o,optional:e.optional,isCorrectType:!0,typeRef:e.typeRef,value:e.optional?void 0:b.get(e.type),description:e.description}}#B(e){let o=e.split("."),{parameter:t,parentParameter:n}=this.#c(o);if(t){switch(t.type){case"array":{let r=t.typeRef;if(!r)throw new Error("Every array parameter must have a typeRef");let s=this.typesByName.get(r)??[],l=s.map(p=>this.#y(p,p.name)),c=H(r)?r:"object";s.length===0&&this.enumsByName.get(r)&&(c="string"),t.value||(t.value=[]),t.value.push({type:c,name:String(t.value.length),optional:!0,typeRef:r,value:l.length!==0?l:"",description:"",isCorrectType:!0});break}case"object":{let r=t.typeRef;if(r||(r=S),t.value||(t.value=[]),!this.typesByName.get(r)){t.value.push({type:"string",name:"",optional:!0,value:"",isCorrectType:!0,description:"",isKeyEditable:!0});break}let s=this.typesByName.get(r)??[],l=s.map(p=>this.#y(p,p.name)),c=s.map(p=>this.#p(p));n?t.value.push({type:"object",name:"",optional:!0,typeRef:r,value:l,isCorrectType:!0,description:""}):t.value=c;break}default:t.value=b.get(t.type);break}this.requestUpdate()}}#P(e,o){if(e?.value!==void 0){switch(e.type){case"object":if(e.optional&&!o){e.value=void 0;break}!e.typeRef||!this.typesByName.get(e.typeRef)?e.value=[]:e.value.forEach(t=>this.#P(t,o));break;case"array":e.value=e.optional?void 0:[];break;default:e.value=e.optional?void 0:b.get(e.type),e.isCorrectType=!0;break}this.requestUpdate()}}#x(e,o){if(e&&Array.isArray(o.value)){if(o.value.splice(o.value.findIndex(t=>t===e),1),o.type==="array")for(let t=0;t<o.value.length;t++)o.value[t].name=String(t);this.requestUpdate()}}#N(e){e.target instanceof HTMLSelectElement&&(this.targetId=e.target.value),this.requestUpdate()}#w(e){if(e.type==="string"){let o=this.enumsByName.get(`${e.typeRef}`)??{};return Object.values(o)}return e.type==="boolean"?["true","false"]:[]}performUpdate(){let e={onParameterValueBlur:t=>{this.#b(t)},onParameterKeydown:t=>{this.#T(t)},onParameterFocus:t=>{this.#E(t)},onParameterKeyBlur:t=>{this.#I(t)},onKeydown:t=>{t.key==="Enter"&&(t.ctrlKey||t.metaKey)&&(this.#T(t),this.#v())},parameters:this.parameters,metadataByCommand:this.metadataByCommand,command:this.command,typesByName:this.typesByName,onCommandInputBlur:t=>this.#R(t),onCommandSend:()=>this.#v(),onCopyToClipboard:()=>this.#S(),targets:this.targets,targetId:this.targetId,onAddParameter:t=>{this.#B(t)},onClearParameter:(t,n)=>{this.#P(t,n)},onDeleteParameter:(t,n)=>{this.#x(t,n)},onTargetSelected:t=>{this.#N(t)},computeDropdownValues:t=>this.#w(t),displayTargetSelector:this.displayTargetSelector,displayCommandInput:this.displayCommandInput,displayToolbar:this.displayToolbar},o={};this.#m(e,o,this.contentElement)}};function H(a){return a==="string"||a==="boolean"||a==="number"}function Ae(a){return m`
  <div class="row attribute padded">
    <div>target<span class="separator">:</span></div>
    <select class="target-selector"
            title=${y(g.selectTarget)}
            jslog=${M.dropDown("target-selector").track({change:!0})}
            @change=${a.onTargetSelected}>
      ${a.targets.map(e=>m`
        <option jslog=${M.item("target").track({click:!0,resize:!0})}
                value=${e.id()} .selected=${e.id()===a.targetId}>
          ${e.name()} (${e.inspectedURL()})
        </option>`)}
    </select>
  </div>
`}function T(a){return m`
          <devtools-button
            title=${a.title}
            .size=${O.Button.Size.SMALL}
            .iconName=${a.iconName}
            .variant=${O.Button.Variant.ICON}
            class=${j(a.classMap)}
            @click=${a.onClick}
            .jslogContext=${a.jslogContext}
          ></devtools-button>
      `}function Oe(){return m`<devtools-icon name='warning-filled' class='warning-icon small'>
  </devtools-icon>`}function ne(a,e,o,t,n){return e.sort((r,s)=>Number(r.optional)-Number(s.optional)),m`
    <ul>
      ${Me(e,r=>{let s=t?`${n}.${r.name}`:r.name,l=r.type==="array"||r.type==="object"?r.value??[]:[],c=H(r.type),p=r.type==="array",v=t&&t.type==="array",F=t&&t.type==="object",A=r.type==="object",$=r.value===void 0,V=r.optional,Q=A&&r.typeRef&&a.typesByName.get(r.typeRef)!==void 0,D=r.isKeyEditable,Pe=A&&!Q,k=r.type==="string"||r.type==="boolean",we=p&&!$&&r.value?.length!==0||A&&!$,Ce={"optional-parameter":r.optional,parameter:!0,"undefined-parameter":r.value===void 0&&r.optional},$e={"json-input":!0};return m`
              <li class="row">
                <div class="row-icons">
                    ${r.isCorrectType?u:m`${Oe()}`}

                    <!-- If an object parameter has no predefined keys, show an input to enter the key, otherwise show the name of the parameter -->
                    <div class=${j(Ce)} data-paramId=${s}>
                        ${D?m`<devtools-suggestion-input
                            data-paramId=${s}
                            .isKey=${!0}
                            .isCorrectInput=${P(r.isCorrectType)}
                            .options=${k?a.computeDropdownValues(r):[]}
                            .autocomplete=${!1}
                            .value=${P(r.name??"")}
                            .placeholder=${r.value===""?U:`<${b.get(r.type)}>`}
                            @blur=${a.onParameterKeyBlur}
                            @focus=${a.onParameterFocus}
                            @keydown=${a.onParameterKeydown}
                          ></devtools-suggestion-input>`:m`${r.name}`} <span class="separator">:</span>
                    </div>

                    <!-- Render button to add values inside an array parameter -->
                    ${p?m`
                      ${T({title:y(g.addParameter),iconName:"plus",onClick:()=>a.onAddParameter(s),classMap:{"add-button":!0},jslogContext:"protocol-monitor.add-parameter"})}
                    `:u}

                    <!-- Render button to complete reset an array parameter or an object parameter-->
                    ${we?T({title:y(g.resetDefaultValue),iconName:"clear",onClick:()=>a.onClearParameter(r,v),classMap:{"clear-button":!0},jslogContext:"protocol-monitor.reset-to-default-value"}):u}

                    <!-- Render the buttons to change the value from undefined to empty string for optional primitive parameters -->
                    ${c&&!v&&V&&$?m`  ${T({title:y(g.addParameter),iconName:"plus",onClick:()=>a.onAddParameter(s),classMap:{"add-button":!0},jslogContext:"protocol-monitor.add-parameter"})}`:u}

                    <!-- Render the buttons to change the value from undefined to populate the values inside object with their default values -->
                    ${A&&V&&$&&Q?m`  ${T({title:y(g.addParameter),iconName:"plus",onClick:()=>a.onAddParameter(s),classMap:{"add-button":!0},jslogContext:"protocol-monitor.add-parameter"})}`:u}
                </div>

                <div class="row-icons">
                    <!-- If an object has no predefined keys, show an input to enter the value, and a delete icon to delete the whole key/value pair -->
                    ${D&&F?m`
                    <!-- @ts-ignore -->
                    <devtools-suggestion-input
                        data-paramId=${s}
                        .isCorrectInput=${P(r.isCorrectType)}
                        .options=${k?a.computeDropdownValues(r):[]}
                        .autocomplete=${!1}
                        .value=${P(r.value??"")}
                        .placeholder=${r.value===""?U:`<${b.get(r.type)}>`}
                        .jslogContext=${"parameter-value"}
                        @blur=${a.onParameterValueBlur}
                        @focus=${a.onParameterFocus}
                        @keydown=${a.onParameterKeydown}
                      ></devtools-suggestion-input>

                      ${T({title:y(g.deleteParameter),iconName:"bin",onClick:()=>a.onDeleteParameter(r,t),classMap:{deleteButton:!0,deleteIcon:!0},jslogContext:"protocol-monitor.delete-parameter"})}`:u}

                  <!-- In case  the parameter is not optional or its value is not undefined render the input -->
                  ${c&&!D&&(!$||!V)&&!v?m`
                      <!-- @ts-ignore -->
                      <devtools-suggestion-input
                        data-paramId=${s}
                        .strikethrough=${P(r.isCorrectType)}
                        .options=${k?a.computeDropdownValues(r):[]}
                        .autocomplete=${!1}
                        .value=${P(r.value??"")}
                        .placeholder=${r.value===""?U:`<${b.get(r.type)}>`}
                        .jslogContext=${"parameter-value"}
                        @blur=${a.onParameterValueBlur}
                        @focus=${a.onParameterFocus}
                        @keydown=${a.onParameterKeydown}
                      ></devtools-suggestion-input>`:u}

                  <!-- Render the buttons to change the value from empty string to undefined for optional primitive parameters -->
                  ${c&&!D&&!v&&V&&!$?m`  ${T({title:y(g.resetDefaultValue),iconName:"clear",onClick:()=>a.onClearParameter(r),classMap:{"clear-button":!0},jslogContext:"protocol-monitor.reset-to-default-value"})}`:u}

                  <!-- If the parameter is an object with no predefined keys, renders a button to add key/value pairs to it's value -->
                  ${Pe?m`
                    ${T({title:y(g.addCustomProperty),iconName:"plus",onClick:()=>a.onAddParameter(s),classMap:{"add-button":!0},jslogContext:"protocol-monitor.add-custom-property"})}
                  `:u}

                  <!-- In case the parameter is nested inside an array we render the input field as well as a delete button -->
                  ${v?m`
                  <!-- If the parameter is an object we don't want to display the input field we just want the delete button-->
                  ${A?u:m`
                  <!-- @ts-ignore -->
                  <devtools-suggestion-input
                    data-paramId=${s}
                    .options=${k?a.computeDropdownValues(r):[]}
                    .autocomplete=${!1}
                    .value=${P(r.value??"")}
                    .placeholder=${r.value===""?U:`<${b.get(r.type)}>`}
                    .jslogContext=${"parameter"}
                    @blur=${a.onParameterValueBlur}
                    @keydown=${a.onParameterKeydown}
                    class=${j($e)}
                  ></devtools-suggestion-input>`}

                  ${T({title:y(g.deleteParameter),iconName:"bin",onClick:()=>a.onDeleteParameter(r,t),classMap:{"delete-button":!0},jslogContext:"protocol-monitor.delete-parameter"})}`:u}
                </div>
              </li>
              ${ne(a,l,o,r,s)}
            `})}
    </ul>
  `}var se=(a,e,o)=>{Ee(m`
    <div class="wrapper" @keydown=${a.onKeydown} jslog=${M.pane("command-editor").track({resize:!0})}>
      <div class="editor-wrapper">
        ${a.displayTargetSelector!==!1?Ae(a):u}
        ${a.displayCommandInput!==!1?m`
        <div class="row attribute padded">
          <div class="command">command<span class="separator">:</span></div>
          <devtools-suggestion-input
            .options=${[...a.metadataByCommand.keys()]}
            .value=${a.command}
            .placeholder=${"Enter your command\u2026"}
            .suggestionFilter=${re}
            .jslogContext=${"command"}
            @blur=${a.onCommandInputBlur}
            class=${j({"json-input":!0})}
          ></devtools-suggestion-input>
        </div>`:u}
        ${a.parameters.length?m`
        <div class="row attribute padded">
          <div>parameters<span class="separator">:</span></div>
        </div>
          ${ne(a,a.parameters)}
        `:u}
      </div>
      ${a.displayToolbar!==!1?m`
      <devtools-toolbar class="protocol-monitor-sidebar-toolbar">
        <devtools-button title=${y(g.copyCommand)}
                        .iconName=${"copy"}
                        .jslogContext=${"protocol-monitor.copy-command"}
                        .variant=${O.Button.Variant.TOOLBAR}
                        @click=${a.onCopyToClipboard}></devtools-button>
          <div class=toolbar-spacer></div>
        <devtools-button title=${L.Platform.isMac()?y(g.sendCommandCmdEnter):y(g.sendCommandCtrlEnter)}
                        .iconName=${"send"}
                        jslogContext="protocol-monitor.send-command"
                        .variant=${O.Button.Variant.PRIMARY_TOOLBAR}
                        @click=${a.onCommandSend}></devtools-button>
      </devtools-toolbar>
      `:u}
    </div>`,o)};var Te={};X(Te,{CommandAutocompleteSuggestionProvider:()=>q,DEFAULT_VIEW:()=>be,InfoWidget:()=>J,ProtocolMonitorImpl:()=>G,buildProtocolMetadata:()=>ve,parseCommandInput:()=>z});import"../../ui/legacy/legacy.js";import"../../ui/legacy/components/data_grid/data_grid.js";import*as me from"../../core/common/common.js";import*as Y from"../../core/i18n/i18n.js";import*as ce from"../../core/platform/platform.js";import*as N from"../../core/protocol_client/protocol_client.js";import*as w from"../../core/sdk/sdk.js";import*as pe from"../../core/text_utils/text_utils.js";import*as ue from"../../models/bindings/bindings.js";import*as ge from"../../models/workspace/workspace.js";import*as B from"../../ui/components/buttons/buttons.js";import*as he from"../../ui/helpers/helpers.js";import*as _ from"../../ui/legacy/components/source_frame/source_frame.js";import*as f from"../../ui/legacy/legacy.js";import{Directives as Ve,html as h,render as ye}from"../../ui/lit/lit.js";import*as C from"../../ui/visual_logging/visual_logging.js";var de=`@scope to (devtools-widget > *){.protocol-monitor-toolbar{border-bottom:var(--sys-size-1) solid var(--sys-color-divider)}.protocol-monitor-bottom-toolbar{border-top:var(--sys-size-1) solid var(--sys-color-divider)}.target-selector{max-width:120px}.protocol-monitor-main{flex-grow:1}}
/*# sourceURL=${import.meta.resolve("./protocolMonitor.css")} */`;var{styleMap:le}=Ve,{widget:x,widgetRef:De}=f.Widget,i={method:"Method",type:"Type",request:"Request",response:"Response",timestamp:"Timestamp",elapsedTime:"Elapsed time",target:"Target",record:"Record",clearAll:"Clear all",filter:"Filter",documentation:"Documentation",editAndResend:"Edit and resend",sMs:"{PH1} ms",noMessageSelected:"No message selected",selectAMessageToView:"Select a message to see its details",save:"Save",session:"Session",sendRawCDPCommand:"Send a raw CDP command",sendRawCDPCommandExplanation:`Format: 'Domain.commandName' for a command without parameters, or '{"command":"Domain.commandName", "parameters": {\u2026}}' as a JSON object for a command with parameters. 'cmd'/'method' and 'args'/'params'/'arguments' are also supported as alternative keys for the JSON object.`,selectTarget:"Select target",showCDPCommandEditor:"Show CDP command editor",hideCDPCommandEditor:"Hide CDP command editor"},ke=Y.i18n.registerUIStrings("panels/protocol_monitor/ProtocolMonitor.ts",i),d=Y.i18n.getLocalizedString.bind(void 0,ke),ve=a=>{let e=new Map;for(let o of a)for(let t of Object.keys(o.metadata))e.set(t,o.metadata[t]);return e},fe=ve(N.InspectorBackend.inspectorBackend.agentPrototypes.values()),Ue=N.InspectorBackend.inspectorBackend.typeMap,je=N.InspectorBackend.inspectorBackend.enumMap,be=(a,e,o)=>{ye(h`
        <style>${f.inspectorCommonStyles}</style>
        <style>${de}</style>
        <devtools-split-view name="protocol-monitor-split-container"
                             direction="column"
                             sidebar-initial-size="400"
                             show=${a.sidebarVisible?"both":"main"}
                             @change=${t=>a.onSplitChange(t.detail==="OnlyMain")}>
          <div slot="main" class="vbox protocol-monitor-main">
            <devtools-toolbar class="protocol-monitor-toolbar"
                               jslog=${C.toolbar("top")}>
               <devtools-button title=${d(i.record)}
                                .iconName=${"record-start"}
                                .toggledIconName=${"record-stop"}
                                .jslogContext=${"protocol-monitor.toggle-recording"}
                                .variant=${B.Button.Variant.ICON_TOGGLE}
                                .toggleType=${B.Button.ToggleType.RED}
                                .toggled=${!0}
                                @click=${t=>a.onRecord(t.target.toggled)}>
               </devtools-button>
              <devtools-button title=${d(i.clearAll)}
                               .iconName=${"clear"}
                               .variant=${B.Button.Variant.TOOLBAR}
                               .jslogContext=${"protocol-monitor.clear-all"}
                               @click=${()=>a.onClear()}></devtools-button>
              <devtools-button title=${d(i.save)}
                               .iconName=${"download"}
                               .variant=${B.Button.Variant.TOOLBAR}
                               .jslogContext=${"protocol-monitor.save"}
                               @click=${()=>a.onSave()}></devtools-button>
              <devtools-toolbar-input type="filter"
                                      list="filter-suggestions"
                                      style="flex-grow: 1"
                                      value=${a.filter}
                                      @change=${t=>a.onFilterChanged(t.detail)}>
                <datalist id="filter-suggestions">
                  ${a.filterKeys.map(t=>h`
                        <option value=${t+":"}></option>
                        <option value=${"-"+t+":"}></option>`)}
                </datalist>
              </devtools-toolbar-input>
            </devtools-toolbar>
            <devtools-split-view direction="column" sidebar-position="second"
                                 name="protocol-monitor-panel-split" sidebar-initial-size="250">
              <devtools-data-grid
                  striped
                  autoscroll
                  slot="main"
                  .columnsVisibilitySetting=${a.columnsVisibilitySetting}
                  .filters=${a.parseFilter(a.filter)}>
                <table>
                    <tr>
                      <th id="type" sortable style="text-align: center" hideable weight="1">
                        ${d(i.type)}
                      </th>
                      <th id="method" weight="5">
                        ${d(i.method)}
                      </th>
                      <th id="request" hideable weight="5">
                        ${d(i.request)}
                      </th>
                      <th id="response" hideable weight="5">
                        ${d(i.response)}
                      </th>
                      <th id="elapsed-time" sortable hideable weight="2">
                        ${d(i.elapsedTime)}
                      </th>
                      <th id="timestamp" sortable hideable weight="5">
                        ${d(i.timestamp)}
                      </th>
                      <th id="target" sortable hideable weight="5">
                        ${d(i.target)}
                      </th>
                      <th id="session" sortable hideable weight="5">
                        ${d(i.session)}
                      </th>
                    </tr>
                    ${a.messages.map(t=>h`
                      <tr @select=${()=>a.onSelect(t)}
                          @contextmenu=${n=>a.onContextMenu(t,n.detail)}
                          style="--override-data-grid-row-background-color: var(--sys-color-surface3)">
                        ${"id"in t?h`
                          <td title="sent">
                            <devtools-icon name="arrow-up-down" class="medium" style="color: var(--icon-request-response);">
                            </devtools-icon>
                          </td>`:h`
                          <td title="received">
                            <devtools-icon name="arrow-down" class="medium" style="color: var(--icon-request);">
                            </devtools-icon>
                          </td>`}
                        <td>${t.method}</td>
                        <td>${t.params?h`<code>${JSON.stringify(t.params)}</code>`:""}</td>
                        <td>
                          ${t.result?h`<code>${JSON.stringify(t.result)}</code>`:t.error?h`<code>${JSON.stringify(t.error)}</code>`:"id"in t?"(pending)":""}
                        </td>
                        <td data-value=${t.elapsedTime||0}>
                          ${"id"in t?t.elapsedTime?d(i.sMs,{PH1:String(t.elapsedTime)}):"(pending)":""}
                        </td>
                        <td data-value=${t.requestTime}>${d(i.sMs,{PH1:String(t.requestTime)})}</td>
                        <td>${Ke(t.target)}</td>
                        <td>${t.sessionId||""}</td>
                      </tr>`)}
                  </table>
              </devtools-data-grid>
              <devtools-widget ${x(J,{request:a.selectedMessage?.params,response:a.selectedMessage?.result||a.selectedMessage?.error,type:a.selectedMessage?"id"in a?.selectedMessage?"sent":"received":void 0})}
                  class="protocol-monitor-info"
                  slot="sidebar"></devtools-widget>
            </devtools-split-view>
            <devtools-toolbar class="protocol-monitor-bottom-toolbar"
               jslog=${C.toolbar("bottom")}>
              <devtools-button .title=${a.sidebarVisible?d(i.hideCDPCommandEditor):d(i.showCDPCommandEditor)}
                               .iconName=${a.sidebarVisible?"left-panel-close":"left-panel-open"}
                               .variant=${B.Button.Variant.TOOLBAR}
                               .jslogContext=${"protocol-monitor.toggle-command-editor"}
                               @click=${()=>a.onToggleSidebar()}></devtools-button>
              </devtools-button>
              <devtools-toolbar-input id="command-input"
                                      style=${le({"flex-grow":1,display:a.sidebarVisible?"none":"flex"})}
                                      value=${a.command}
                                      list="command-input-suggestions"
                                      placeholder=${d(i.sendRawCDPCommand)}
                                      title=${d(i.sendRawCDPCommandExplanation)}
                                      @change=${t=>a.onCommandChange(t.detail)}
                                      @submit=${t=>a.onCommandSubmitted(t.detail)}>
                <datalist id="command-input-suggestions">
                  ${a.commandSuggestions.map(t=>h`<option value=${t}></option>`)}
                </datalist>
              </devtools-toolbar-input>
              <select class="target-selector"
                      title=${d(i.selectTarget)}
                      style=${le({display:a.sidebarVisible?"none":"flex"})}
                      jslog=${C.dropDown("target-selector").track({change:!0})}
                      @change=${t=>a.onTargetChange(t.target.value)}>
                ${a.targets.map(t=>h`
                  <option jslog=${C.item("target").track({click:!0})}
                          value=${t.id()} .selected=${t.id()===a.selectedTargetId}>
                    ${t.name()} (${t.inspectedURL()})
                  </option>`)}
              </select>
            </devtools-toolbar>
          </div>
          <devtools-widget slot="sidebar"
              ${x(R,{metadataByCommand:fe,typesByName:Ue,enumsByName:je})}
              @submiteditor=${t=>a.onEditorSubmit(t.detail.command,t.detail.parameters,t.detail.targetId)}
              ${De(R,t=>{e.editorWidget=t})}>
          </devtools-widget>
        </devtools-split-view>`,o)},G=class extends f.Panel.Panel{started;startTime;messageForId=new Map;filterParser;#t=["method","request","response","target","session"];#e=new q;#a;#i="";#r=!1;#l;#n=[];#o;#m="";#s;#d=new Map;#u=me.Settings.Settings.instance().createSetting("protocol-monitor-columns",{});constructor(e=be){super("protocol-monitor",!0),this.#l=e,this.started=!1,this.startTime=0,this.#t=["method","request","response","type","target","session"],this.filterParser=new pe.TextUtils.FilterParser(this.#t),this.#a="main",this.performUpdate(),w.TargetManager.TargetManager.instance().addEventListener(w.TargetManager.Events.AVAILABLE_TARGETS_CHANGED,()=>{this.requestUpdate()}),w.TargetManager.TargetManager.instance().observeTargets(this)}targetAdded(e){this.#d.set(e.sessionId,e)}targetRemoved(e){this.#d.delete(e.sessionId)}#g(){let e=this.#s.getCommandJson(),o=this.#s.targetId;o&&(this.#a=o),e&&(this.#i=e,this.requestUpdate())}performUpdate(){let e={messages:this.#n,selectedMessage:this.#o,sidebarVisible:this.#r,command:this.#i,commandSuggestions:this.#e.allSuggestions(),filterKeys:this.#t,filter:this.#m,parseFilter:this.filterParser.parse.bind(this.filterParser),onSplitChange:n=>{if(n)this.#g(),this.#r=!1;else{let{command:r,parameters:s}=z(this.#i);this.#s.displayCommand(r,s,this.#a),this.#r=!0}this.requestUpdate()},onRecord:n=>{this.setRecording(n)},onClear:()=>{this.#n=[],this.messageForId.clear(),this.requestUpdate()},onSave:()=>{this.saveAsFile()},onSelect:n=>{this.#o=n,this.requestUpdate()},onContextMenu:this.#h.bind(this),onCommandChange:n=>{this.#i=n},onCommandSubmitted:n=>{this.#e.addEntry(n);let{command:r,parameters:s}=z(n);this.onCommandSend(r,s,this.#a)},onFilterChanged:n=>{this.#m=n,this.requestUpdate()},onTargetChange:n=>{this.#a=n},onToggleSidebar:()=>{this.#r=!this.#r,this.requestUpdate()},onEditorSubmit:(n,r,s)=>{this.onCommandSend(n,r,s)},columnsVisibilitySetting:this.#u,targets:w.TargetManager.TargetManager.instance().targets(),selectedTargetId:this.#a},o=this,t={set editorWidget(n){o.#s=n}};this.#l(e,t,this.contentElement)}#h(e,o){o.editSection().appendItem(d(i.editAndResend),()=>{if(!this.#o)return;let t=this.#o.params,n=this.#o.target?.id()||"",r=e.method;this.#i=JSON.stringify({command:r,parameters:t}),this.#r?this.#s.displayCommand(r,t,n):(this.#r=!0,this.requestUpdate())},{jslogContext:"edit-and-resend",disabled:!("id"in e)}),o.editSection().appendItem(d(i.filter),()=>{this.#m=`method:${e.method}`,this.requestUpdate()},{jslogContext:"filter"}),o.footerSection().appendItem(d(i.documentation),()=>{let[t,n]=e.method.split("."),r="id"in e?"method":"event";he.openInNewTab(`https://chromedevtools.github.io/devtools-protocol/tot/${t}#${r}-${n}`)},{jslogContext:"documentation"})}onCommandSend(e,o,t){let n=N.InspectorBackend.test,r=w.TargetManager.TargetManager.instance(),s=t?r.targetById(t):null,l=s?s.sessionId:"";n.sendRawMessage(e,o,()=>{},l)}wasShown(){super.wasShown(),!this.started&&(this.started=!0,this.startTime=Date.now(),this.setRecording(!0))}setRecording(e){let o=N.InspectorBackend.test;e?(o.onMessageSent=this.messageSent.bind(this),o.onMessageReceived=this.messageReceived.bind(this)):(o.onMessageSent=null,o.onMessageReceived=null)}messageReceived(e){if("id"in e&&e.id){let t=this.messageForId.get(e.id);if(!t)return;t.result=e.result,t.error=e.error,t.elapsedTime=Date.now()-this.startTime-t.requestTime,this.messageForId.delete(e.id),this.requestUpdate();return}let o=e.sessionId!==void 0?this.#d.get(e.sessionId):void 0;this.#n.push({method:e.method,sessionId:e.sessionId,target:o,requestTime:Date.now()-this.startTime,result:e.params}),this.requestUpdate()}messageSent(e){let o=e.sessionId!==void 0?this.#d.get(e.sessionId):void 0,t={method:e.method,params:e.params,id:e.id,sessionId:e.sessionId,target:o,requestTime:Date.now()-this.startTime};this.#n.push(t),this.requestUpdate(),this.messageForId.set(e.id,t)}async saveAsFile(){let e=new Date,o="ProtocolMonitor-"+ce.DateUtilities.toISO8601Compact(e)+".json",t=new ue.FileUtils.FileOutputStream(ge.FileManager.FileManager.instance());if(!await t.open(o))return;let r=this.#n.map(s=>({...s,target:s.target?.id()}));t.write(JSON.stringify(r,null,"  ")),t.close()}},q=class{#t=200;#e=new Set;constructor(e){e!==void 0&&(this.#t=e)}allSuggestions(){let e=[...this.#e].reverse();return e.push(...fe.keys()),e}buildTextPromptCompletions=async(e,o,t)=>!o&&!t&&e?[]:this.allSuggestions().filter(r=>r.startsWith(o)).map(r=>({text:r}));addEntry(e){if(this.#e.has(e)&&this.#e.delete(e),this.#e.add(e),this.#e.size>this.#t){let o=this.#e.values().next().value;this.#e.delete(o)}}},Le=(a,e,o)=>{ye(h`
    <devtools-tabbed-pane>${a.type===void 0?h`
      <devtools-widget
          id="request" label=${d(i.request)}
          ?selected=${a.selectedTab==="request"} disabled
          ${x(f.EmptyWidget.EmptyWidget,{header:d(i.noMessageSelected),text:d(i.selectAMessageToView)})}>
      </devtools-widget>
      <devtools-widget
          id="response" label=${d(i.response)}
          ?selected=${a.selectedTab==="response"}
          ${x(f.EmptyWidget.EmptyWidget,{header:d(i.noMessageSelected),text:d(i.selectAMessageToView)})}>
      </devtools-widget>`:h`
      <devtools-widget
          id="request" label=${d(i.request)}
          ?selected=${a.selectedTab==="request"} ?disabled=${a.type!=="sent"}
          ${x(_.JSONView.SearchableJsonView,{jsonObject:a.request})}>
      </devtools-widget>
      <devtools-widget
          id="response" label=${d(i.response)}
          ?selected=${a.selectedTab==="response"}
          ${x(_.JSONView.SearchableJsonView,{jsonObject:a.response})}>
      </devtools-widget>`}
    </devtools-tabbed-pane>`,o)},J=class extends f.Widget.VBox{#t;request;response;type;constructor(e,o=Le){super(e),this.#t=o,this.requestUpdate()}performUpdate(){this.#t({request:this.request,response:this.response,type:this.type,selectedTab:this.type!=="sent"?"response":void 0},void 0,this.contentElement)}};function z(a){let e=null;try{e=JSON.parse(a)}catch{}let o=e?e.command||e.method||e.cmd||"":a,t=e?.parameters||e?.params||e?.args||e?.arguments||{};return{command:o,parameters:t}}function Ke(a){return a?a.decorateLabel(`${a.name()} ${a===w.TargetManager.TargetManager.instance().rootTarget()?"":a.id()}`):""}export{ie as JSONEditor,Te as ProtocolMonitor};
//# sourceMappingURL=protocol_monitor.js.map
