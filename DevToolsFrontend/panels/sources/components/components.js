var V=Object.defineProperty;var M=(i,t)=>{for(var e in t)V(i,e,{get:t[e],enumerable:!0})};var I={};M(I,{DEFAULT_VIEW:()=>S,HEADERS_VIEW_DEFAULT_VIEW:()=>$,HeadersView:()=>H,HeadersViewComponent:()=>w});import*as E from"../../../core/host/host.js";import*as g from"../../../core/i18n/i18n.js";import*as L from"../../../core/text_utils/text_utils.js";import*as T from"../../../models/persistence/persistence.js";import*as v from"../../../models/workspace/workspace.js";import*as c from"../../../ui/components/buttons/buttons.js";import*as k from"../../../ui/components/helpers/helpers.js";import*as y from"../../../ui/legacy/legacy.js";import*as u from"../../../ui/lit/lit.js";import*as d from"../../../ui/visual_logging/visual_logging.js";var C=`:host{flex-grow:1;padding:var(--sys-size-4)}.row{display:flex;flex-direction:row;color:var(--sys-color-token-property-special);font-family:var(--monospace-font-family);font-size:var(--monospace-font-size);align-items:center;line-height:var(--sys-typescale-body1-line-height)}.row devtools-button{line-height:1;margin-left:0.1em}.row devtools-button:nth-of-type(1){margin-left:0.8em}.padded{margin-left:2em}.separator{margin-right:0.5em;color:var(--sys-color-on-surface)}.editable{cursor:text;color:var(--sys-color-on-surface);overflow-wrap:break-word;min-height:18px;line-height:18px;min-width:0.5em;background:transparent;border:none;outline:none;display:inline-block}.editable.red{color:var(--sys-color-token-property-special)}.editable:hover,
.editable:focus{border:var(--sys-size-1) solid var(--sys-color-neutral-outline);border-radius:var(--sys-size-2)}.row .inline-button{opacity:0%;visibility:hidden;transition:opacity 200ms}.row:focus-within .inline-button:not([hidden]),
.row:hover .inline-button:not([hidden]){opacity:100%;visibility:visible}.center-wrapper{height:100%;display:flex;justify-content:center;align-items:center}.centered{margin:1em;max-width:300px;text-align:center}.error-header{font-weight:bold;margin-bottom:1em}.error-body{line-height:1.5em;color:var(--sys-color-token-subtle)}.add-block{margin-top:3px}.header-name,
.header-value{min-width:min-content}.link{color:var(--sys-color-primary);text-decoration:underline;cursor:pointer;outline-offset:var(--sys-size-2);padding:0}.learn-more-row{line-height:var(--sys-typescale-body1-line-height)}
/*# sourceURL=${import.meta.resolve("./HeadersView.css")} */`;var{html:h,Directives:{ref:N}}=u,p={addHeader:"Add a header",removeHeader:"Remove this header",removeBlock:"Remove this '`ApplyTo`'-section",errorWhenParsing:"Error when parsing ''{PH1}''",parsingErrorExplainer:"This is most likely due to a syntax error in ''{PH1}''. Try opening this file in an external editor to fix the error or delete the file and re-create the override.",addOverrideRule:"Add override rule",learnMore:"Learn more"},O=g.i18n.registerUIStrings("panels/sources/components/HeadersView.ts",p),m=g.i18n.getLocalizedString.bind(void 0,O),b="header value",f=i=>`header-name-${i}`,$=(i,t,e)=>{u.render(h`
    <devtools-sources-headers-view
      .data=${i.data}
      ${N(r=>{r&&(t.component=r)})}
    ></devtools-sources-headers-view>
  `,e)},H=class extends y.View.SimpleView{#t;#e;#r;#i;constructor(t,e=$){super({title:g.i18n.lockedString("HeadersView"),viewId:"headers-view",jslog:`${d.pane("headers-view")}`}),this.#r=e,this.#e=t,this.#i={headerOverrides:[],uiSourceCode:this.#e,parsingError:!1},this.#e.addEventListener(v.UISourceCode.Events.WorkingCopyChanged,this.#a,this),this.#e.addEventListener(v.UISourceCode.Events.WorkingCopyCommitted,this.#d,this),this.performUpdate(),this.#o()}performUpdate(){let t=this,e={set component(r){r&&(t.#t=r)}};this.#r({data:this.#i},e,this.contentElement)}async#o(){let t=await this.#e.requestContentData();this.#s(L.ContentData.ContentData.textOr(t,""))}#s(t){let e=!1,r=[];t=t||"[]";try{if(r=JSON.parse(t),!r.every(T.NetworkPersistenceManager.isHeaderOverride))throw new Error("Type mismatch after parsing")}catch{console.error("Failed to parse",this.#e.url(),"for locally overriding headers."),e=!0}this.#i={headerOverrides:r,uiSourceCode:this.#e,parsingError:e},this.performUpdate()}#a(){this.#s(this.#e.workingCopy())}#d(){this.#s(this.#e.workingCopy())}getComponent(){return this.#t}dispose(){this.#e.removeEventListener(v.UISourceCode.Events.WorkingCopyChanged,this.#a,this),this.#e.removeEventListener(v.UISourceCode.Events.WorkingCopyCommitted,this.#d,this)}},w=class extends HTMLElement{#t=this.attachShadow({mode:"open"});#e=[];#r=null;#i=!1;#o=null;#s="";constructor(){super(),this.#t.addEventListener("focusin",this.#m.bind(this)),this.#t.addEventListener("focusout",this.#u.bind(this)),this.#t.addEventListener("click",this.#g.bind(this)),this.#t.addEventListener("input",this.#f.bind(this)),this.#t.addEventListener("keydown",this.#a.bind(this)),this.#t.addEventListener("paste",this.#w.bind(this)),this.addEventListener("contextmenu",this.#v.bind(this))}set data(t){this.#e=t.headerOverrides,this.#r=t.uiSourceCode,this.#i=t.parsingError,k.ScheduledRender.scheduleRender(this,this.#E)}#a(t){let e=t.target;if(!e.matches(".editable"))return;let r=t;e.matches(".header-name")&&e.innerText===""&&(r.key==="Enter"||r.key==="Tab")?(t.preventDefault(),e.blur()):r.key==="Enter"?(t.preventDefault(),e.blur(),this.#d(e)):r.key==="Escape"&&(t.consume(),e.innerText=this.#s,e.blur(),this.#l(e))}#d(t){let e=Array.from(this.#t.querySelectorAll(".editable")),r=e.indexOf(t);r!==-1&&r+1<e.length&&e[r+1].focus()}#p(t){let e=window.getSelection(),r=document.createRange();r.selectNodeContents(t),e?.removeAllRanges(),e?.addRange(r)}#m(t){let e=t.target;e.matches(".editable")&&(this.#p(e),this.#s=e.innerText)}#u(t){let e=t.target;if(e.innerText===""){let o=e.closest(".row"),a=Number(o.dataset.blockIndex),n=Number(o.dataset.headerIndex);e.matches(".apply-to")?(e.innerText="*",this.#e[a].applyTo="*",this.#n()):e.matches(".header-name")&&this.#h(a,n)}window.getSelection()?.removeAllRanges(),this.#r?.commitWorkingCopy()}#v(t){if(!this.#r)return;let e=new y.ContextMenu.ContextMenu(t);e.appendApplicableItems(this.#r),e.show()}#c(t){let e=new Set(t.map(o=>o.name)),r=1;for(;e.has(f(r));)r++;return f(r)}#g(t){let e=t.target,r=e.closest(".row"),o=Number(r?.dataset.blockIndex||0),a=Number(r?.dataset.headerIndex||0);e.matches(".add-header")?(this.#e[o].headers.splice(a+1,0,{name:this.#c(this.#e[o].headers),value:b}),this.#o={blockIndex:o,headerIndex:a+1},this.#n()):e.matches(".remove-header")?this.#h(o,a):e.matches(".add-block")?(this.#e.push({applyTo:"*",headers:[{name:f(1),value:b}]}),this.#o={blockIndex:this.#e.length-1},this.#n()):e.matches(".remove-block")&&(this.#e.splice(o,1),this.#n())}#b(t,e){return!(e===0&&this.#e[t].headers.length===1&&this.#e[t].headers[e].name===f(1)&&this.#e[t].headers[e].value===b)}#h(t,e){this.#e[t].headers.splice(e,1),this.#e[t].headers.length===0&&this.#e[t].headers.push({name:this.#c(this.#e[t].headers),value:b}),this.#n()}#f(t){this.#l(t.target)}#l(t){let e=t.closest(".row"),r=Number(e.dataset.blockIndex),o=Number(e.dataset.headerIndex);t.matches(".header-name")&&(this.#e[r].headers[o].name=t.innerText,this.#n()),t.matches(".header-value")&&(this.#e[r].headers[o].value=t.innerText,this.#n()),t.matches(".apply-to")&&(this.#e[r].applyTo=t.innerText,this.#n())}#n(){this.#r?.setWorkingCopy(JSON.stringify(this.#e,null,2)),E.userMetrics.actionTaken(E.UserMetrics.Action.HeaderOverrideHeadersFileEdited)}#w(t){let e=t;if(t.preventDefault(),e.clipboardData){let r=e.clipboardData.getData("text/plain"),o=this.#t.getSelection()?.getRangeAt(0);if(!o)return;o.deleteContents();let a=new Text(r);o.insertNode(a),o.selectNodeContents(a),o.collapse(!1);let n=window.getSelection();n?.removeAllRanges(),n?.addRange(o),this.#l(t.target)}}#E(){if(!k.ScheduledRender.isScheduledRender(this))throw new Error("HeadersView render was not scheduled");let t={};S({headerOverrides:this.#e,parsingError:this.#i,fileName:this.#r?.name()||".headers",isDeletable:(e,r)=>this.#b(e,r)},t,this.#t),this.#o&&(t.focusElement?.(this.#o.blockIndex,this.#o.headerIndex),this.#o=null)}},S=(i,t,e)=>{let r=(n,s,l)=>{let x=l?d.key():d.value();return h`<span jslog=${x.track({change:!0,keydown:"Enter|Escape|Tab",click:!0})}
                              contenteditable="true"
                              class="editable ${s}"
                              tabindex="0"
                              .innerText=${u.Directives.live(n)}></span>`},o=(n,s)=>h`
      <div class="row" data-block-index=${s}
           jslog=${d.treeItem(n==="*"?n:void 0).track({resize:!0})}>
        <div>${g.i18n.lockedString("Apply to")}</div>
        <div class="separator">:</div>
        ${r(n,"apply-to")}
        <devtools-button
          title=${m(p.removeBlock)}
          .size=${c.Button.Size.SMALL}
          .iconName=${"bin"}
          .iconWidth=${"14px"}
          .iconHeight=${"14px"}
          .variant=${c.Button.Variant.ICON}
          .jslogContext=${"headers-view.remove-apply-to-section"}
          class="remove-block inline-button"
        ></devtools-button>
      </div>
    `,a=(n,s,l)=>h`
          <div class="row padded" data-block-index=${s} data-header-index=${l}
               jslog=${d.treeItem(n.name).parent("headers-editor-row-parent").track({resize:!0})}>
            ${r(n.name,"header-name red",!0)}
            <div class="separator">:</div>
            ${r(n.value,"header-value")}
            <devtools-button
              title=${m(p.addHeader)}
              .size=${c.Button.Size.SMALL}
              .iconName=${"plus"}
              .variant=${c.Button.Variant.ICON}
              .jslogContext=${"headers-view.add-header"}
              class="add-header inline-button"
            ></devtools-button>
            <devtools-button
              title=${m(p.removeHeader)}
              .size=${c.Button.Size.SMALL}
              .iconName=${"bin"}
              .variant=${c.Button.Variant.ICON}
              ?hidden=${!i.isDeletable(s,l)}
              .jslogContext=${"headers-view.remove-header"}
              class="remove-header inline-button"
            ></devtools-button>
          </div>
        `;u.render(i.parsingError?h`
              <style>${C}</style>
              <div class="center-wrapper">
                <div class="centered">
                  <div class="error-header">${m(p.errorWhenParsing,{PH1:i.fileName})}</div>
                  <div class="error-body">${m(p.parsingErrorExplainer,{PH1:i.fileName})}</div>
                </div>
              </div>
            `:h`
              <style>${C}</style>
              ${i.headerOverrides.map((n,s)=>h`
                  ${o(n.applyTo,s)}
                  ${n.headers.map((l,x)=>h`
                      ${a(l,s,x)}
                    `)}
                `)}
              <devtools-button
                  .variant=${c.Button.Variant.OUTLINED}
                  .jslogContext=${"headers-view.add-override-rule"}
                  class="add-block">
                ${m(p.addOverrideRule)}
              </devtools-button>
              <div class="learn-more-row">
                <devtools-link
                    href="https://goo.gle/devtools-override"
                    class="link"
                    jslogContext=${"learn-more"}>${m(p.learnMore)}</devtools-link>
              </div>
            `,e),t.focusElement=(n,s)=>{let l=s!==void 0?e.querySelector(`[data-block-index="${n}"][data-header-index="${s}"] .header-name`):e.querySelector(`[data-block-index="${n}"] .apply-to`);l&&l.focus()}};d.registerParentProvider("headers-editor-row-parent",i=>{for(;i.previousElementSibling?.classList?.contains("padded");)i=i.previousElementSibling;return i.previousElementSibling||void 0});customElements.define("devtools-sources-headers-view",w);export{I as HeadersView};
//# sourceMappingURL=components.js.map
