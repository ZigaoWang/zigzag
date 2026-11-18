var Rt=Object.defineProperty;var E=(i,t)=>{for(var e in t)Rt(i,e,{get:t[e],enumerable:!0})};var vt={};E(vt,{ButtonDialog:()=>k});import*as w from"../helpers/helpers.js";import{Directives as Ht,html as Ut,render as Vt}from"../../lit/lit.js";var ct=`:host{white-space:normal}
/*# sourceURL=${import.meta.resolve("./buttonDialog.css")} */`;var mt={};E(mt,{AnimationEndedEvent:()=>I,CONNECTOR_HEIGHT:()=>m,ClickOutsideDialogEvent:()=>R,DIALOG_PADDING_FROM_WINDOW:()=>d,DIALOG_SIDE_PADDING:()=>J,DIALOG_VERTICAL_PADDING:()=>pt,Dialog:()=>$,DialogHorizontalAlignment:()=>M,DialogState:()=>Z,DialogVerticalPosition:()=>Q,ForcedDialogClose:()=>f,MODAL:()=>P,PointerLeftDialogEvent:()=>O});import*as q from"../../../core/i18n/i18n.js";import*as z from"../../../core/platform/platform.js";import*as Y from"../helpers/helpers.js";import*as g from"../render_coordinator/render_coordinator.js";import*as v from"../../lit/lit.js";import*as D from"../../visual_logging/visual_logging.js";import*as ht from"../../legacy/legacy.js";import*as K from"../buttons/buttons.js";var gt=`:host{--override-transparent:rgb(0 0 0 / 0%);display:var(--dialog-display)}dialog::backdrop{background:var(--override-transparent)}dialog{background:transparent;border:none;top:var(--dialog-top);padding:var(--dialog-padding);left:var(--dialog-left);right:var(--dialog-right);margin:var(--dialog-margin);margin-left:var(--dialog-margin-left,0);margin-bottom:var(--dialog-margin-bottom);animation-name:slideIn;animation-duration:100ms;animation-timing-function:cubic-bezier(0,0,0.3,1);overflow:hidden;filter:drop-shadow(0 4px 8px rgb(0 0 0/15%)) drop-shadow(0 1px 3px rgb(0 0 0/30%))}dialog:focus,
dialog:focus-visible{outline:none}#content{min-width:var(--content-min-width);background:var(--sys-color-base-container-elevated);border-radius:var(--sys-shape-corner-small);max-height:var(--dialog-max-height);max-width:var(--dialog-max-width);overflow:auto;outline:none}.dialog-header{display:flex;justify-content:space-between;align-items:center;padding:var(--sys-size-5) var(--sys-size-5) var(--sys-size-5) var(--sys-size-8);&:empty{padding:0;height:var(--sys-size-7)}.dialog-header-text{font:var(--sys-typescale-body2-medium);padding-top:var(--sys-size-3)}devtools-button{margin:3px}}.dialog-content{padding:0 var(--sys-size-8) var(--sys-size-7) var(--sys-size-8);overflow:hidden}@keyframes slideIn{from{transform:translateY(var(--dialog-offset-y));opacity:0%}to{opacity:100%}}
/*# sourceURL=${import.meta.resolve("./dialog.css")} */`;var{html:C}=v,ut={close:"Close"},It=q.i18n.registerUIStrings("ui/components/dialogs/Dialog.ts",ut),Mt=q.i18n.getLocalizedString.bind(void 0,It),F="HTMLDialogElement"in globalThis,m=10,kt=2*m,L=20,J=5,pt=3,d=3*m,P="MODAL",$=class extends HTMLElement{#d=this.attachShadow({mode:"open"});#e=this.#L.bind(this);#s=this.#z.bind(this);#t={origin:P,position:"bottom",horizontalAlignment:"center",getConnectorCustomXPosition:null,dialogShownCallback:null,closeOnESC:!0,closeOnScroll:!0,closeButton:!1,dialogTitle:"",jslogContext:"",state:"expanded"};#o=null;#n=!1;#r=!1;#a=new DOMRect(0,0,0,0);#p=new DOMRect(0,0,0,0);#c=null;#g=null;#m=new MutationObserver(t=>{this.#t.expectedMutationsSelector&&t.every(o=>o.target instanceof Element&&o.target.matches(this.#t.expectedMutationsSelector??""))||this.#e()});#f=new ResizeObserver(this.#y.bind(this));#h=ht.UIUtils.getDevToolsBoundingElement();#v=this.#A.bind(this);get origin(){return this.#t.origin}set origin(t){this.#t.origin=t,this.#i()}set expectedMutationsSelector(t){this.#t.expectedMutationsSelector=t}get expectedMutationsSelector(){return this.#t.expectedMutationsSelector}get position(){return this.#t.position}set position(t){this.#t.position=t,this.#i()}get horizontalAlignment(){return this.#t.horizontalAlignment}set horizontalAlignment(t){this.#t.horizontalAlignment=t,this.#i()}get bestVerticalPosition(){return this.#c}get bestHorizontalAlignment(){return this.#g}get getConnectorCustomXPosition(){return this.#t.getConnectorCustomXPosition}set getConnectorCustomXPosition(t){this.#t.getConnectorCustomXPosition=t,this.#i()}get dialogShownCallback(){return this.#t.dialogShownCallback}get jslogContext(){return this.#t.jslogContext}set dialogShownCallback(t){this.#t.dialogShownCallback=t,this.#i()}set closeOnESC(t){this.#t.closeOnESC=t,this.#i()}set closeOnScroll(t){this.#t.closeOnScroll=t,this.#i()}set closeButton(t){this.#t.closeButton=t,this.#i()}set dialogTitle(t){this.#t.dialogTitle=t,this.#i()}set jslogContext(t){this.#t.jslogContext=t,this.#i()}set state(t){this.#t.state=t,(this.#t.state==="collapsed"||this.#t.state==="disabled")&&this.#e(),this.#i()}#y(){this.#p=this.#l().getBoundingClientRect()}#i(){Y.ScheduledRender.scheduleRender(this,this.#O)}connectedCallback(){window.addEventListener("resize",this.#e),this.#m.observe(this.#h,{childList:!0,subtree:!0}),this.#h.addEventListener("wheel",this.#s),this.style.setProperty("--dialog-padding","0"),this.style.setProperty("--dialog-display",F?"block":"none"),this.style.setProperty("--override-dialog-content-border",`${m}px solid transparent`),this.style.setProperty("--dialog-padding",`${pt}px ${J}px`)}disconnectedCallback(){window.removeEventListener("resize",this.#e),this.#h.removeEventListener("wheel",this.#s),this.#m.disconnect(),this.#f.disconnect()}#l(){if(!this.#o){if(this.#o=this.#d.querySelector("dialog"),!this.#o)throw new Error("Dialog not found");this.#f.observe(this.#o)}return this.#o}getHitArea(){return this.#a}async setDialogVisible(t){if(t){await this.#P();return}this.#u()}async#b(t){if(t.stopPropagation(),t instanceof PointerEvent&&t.pointerType==="")return;let e=this.#D(t),o=this.#x(t);if(!e){if(t.type==="pointermove"){if(o)return;this.dispatchEvent(new O);return}this.dispatchEvent(new R)}}#w(){this.dispatchEvent(new I)}#D(t){let e=this.#p,o=this.bestVerticalPosition==="bottom"?L:-1*L;this.#t.origin===P&&(o=0);let n=t.pageX>=e.left&&t.pageX<=e.left+e.width,c=t.pageY>=e.top+o&&t.pageY<=e.top+e.height+o;return n&&c}#x(t){let e=this.#a,o=t.pageX>=e.left&&t.pageX<=e.left+e.width,n=t.pageY>=e.top&&t.pageY<=e.top+e.height;return o&&n}#S(t){if(!t||t===P)throw new Error("Dialog origin is null");let e=t instanceof Function?t():t;return e instanceof DOMPoint?{top:e.y,bottom:e.y,left:e.x,right:e.x}:e instanceof HTMLElement?e.getBoundingClientRect():e}#T(t,e){return e.right-t.left>t.right-e.left?"left":"right"}#E(t,e,o){return t.bottom+e>o.height&&t.top-e>o.top?"top":"bottom"}#C(){this.#t.origin&&(this.#n=!0,g.read(()=>{let t=this.#h.getBoundingClientRect(),e=t.width,o=t.height,n=t.left,c=t.top,a=t.right;if(this.#t.origin===P){g.write(()=>{this.style.setProperty("--dialog-top",`${c}px`),this.style.setProperty("--dialog-left",`${n}px`),this.style.setProperty("--dialog-margin","auto"),this.style.setProperty("--dialog-margin-left","auto"),this.style.setProperty("--dialog-margin-bottom","auto"),this.style.setProperty("--dialog-max-height",`${o-d}px`),this.style.setProperty("--dialog-max-width",`${e-d}px`),this.style.setProperty("--dialog-right",`${document.body.clientWidth-a}px`)});return}let s=this.#t.origin,l=this.#S(s),{top:r,right:W,bottom:X,left:S}=l,_=(S+W)/2,G=W-S+m,B=document.body.clientWidth,Bt=this.#t.getConnectorCustomXPosition?this.#t.getConnectorCustomXPosition():_;g.write(()=>{this.style.setProperty("--dialog-top","0");let u=this.#l();if(u.style.visibility="hidden",this.#n&&!u.hasAttribute("open")){if(!u.isConnected)return;u.showModal(),this.setAttribute("open",""),this.#n=!1}let{width:Lt,height:$t}=u.getBoundingClientRect();if(this.#g=this.#t.horizontalAlignment==="auto"?this.#T(l,t):this.#t.horizontalAlignment,this.#c=this.#t.position==="auto"?this.#E(l,$t,t):this.#t.position,!(this.#g==="auto"||this.#c==="auto")){switch(this.#a.height=X-r+m,this.#a.width=G,this.style.setProperty("--content-min-width",`${Bt-S+kt+J*2}px`),this.style.setProperty("--dialog-left","auto"),this.style.setProperty("--dialog-right","auto"),this.style.setProperty("--dialog-margin","0"),this.#g){case"left":{let p=Math.max(S,n),T=a-p-d;this.style.setProperty("--dialog-left",`${p}px`),this.#a.x=S,this.style.setProperty("--dialog-max-width",`${T}px`);break}case"right":{let p=B-W,b=B-a,T=Math.max(p,b),Ot=B-T-n-d;this.#a.x=B-T-G,this.style.setProperty("--dialog-right",`${T}px`),this.style.setProperty("--dialog-max-width",`${Ot}px`);break}case"center":{let p=Math.min(e-d,Lt),b=Math.max(_-p*.5,n);b=Math.min(b,a-p),this.style.setProperty("--dialog-left",`${b}px`),this.#a.x=_-G*.5,this.style.setProperty("--dialog-max-width",`${e-d}px`);break}default:z.assertNever(this.#g,`Unknown alignment type: ${this.#g}`)}switch(this.#c){case"top":{this.style.setProperty("--dialog-top","0"),this.style.setProperty("--dialog-margin","auto"),this.style.setProperty("--dialog-margin-bottom",`${innerHeight-r}px`),this.#a.y=r-m,this.style.setProperty("--dialog-offset-y",`${L}px`),this.style.setProperty("--dialog-max-height",`${o-(innerHeight-r)-d}px`);break}case"bottom":{this.style.setProperty("--dialog-top",`${X}px`),this.#a.y=r,this.style.setProperty("--dialog-offset-y",`-${L}px`),this.style.setProperty("--dialog-max-height",`${o-(X-c)-d}px`);break}default:z.assertNever(this.#c,`Unknown position type: ${this.#c}`)}u.close(),u.style.visibility=""}})}))}async#P(){if(!F||this.#n||this.hasAttribute("open"))return;this.#n=!0,this.#C(),await g.done(),this.#n=!1;let t=this.#l();t.isConnected&&(t.hasAttribute("open")||t.showModal(),this.#t.dialogShownCallback&&await this.#t.dialogShownCallback(),this.#y(),document.body.addEventListener("keydown",this.#v))}#z(t){this.#D(t)||!this.#t.closeOnScroll||!this.#l().hasAttribute("open")||(this.#u(),this.dispatchEvent(new f))}#A(t){!this.#l().hasAttribute("open")||!this.#t.closeOnESC||t.key===z.KeyboardUtilities.ESCAPE_KEY&&(t.stopPropagation(),t.preventDefault(),this.#u(),this.dispatchEvent(new f))}#B(t){t.stopPropagation(),t.preventDefault(),!(!this.#l().hasAttribute("open")||!this.#t.closeOnESC)&&this.dispatchEvent(new f)}#L(){this.#o?.hasAttribute("open")&&this.#h!==document.body&&(this.#u(),this.dispatchEvent(new f))}#u(){this.#r||!this.#l().hasAttribute("open")||(this.#r=!0,g.write(()=>{this.#a.width=0,this.removeAttribute("open"),this.#l().close(),this.#r=!1,document.body.removeEventListener("keydown",this.#v)}))}getDialogBounds(){return this.#p}#$(){return!this.#t.dialogTitle&&!this.#t.closeButton?null:C`
        <span class="dialog-header-text">${this.#t.dialogTitle}</span>
        ${this.#t.closeButton?C`
          <devtools-button
            @click=${this.#u}
            .data=${{variant:K.Button.Variant.TOOLBAR,iconName:"cross",title:Mt(ut.close),size:K.Button.Size.SMALL}}
            jslog=${D.close().track({click:!0})}
          ></devtools-button>
        `:v.nothing}
    `}#O(){if(!Y.ScheduledRender.isScheduledRender(this))throw new Error("Dialog render was not scheduled");if(!F){v.render(C`
        <slot></slot>
      `,this.#d,{host:this});return}let t=v.nothing;this.#t.state==="expanded"&&(t=C`
    <div id="content">
          <div class="dialog-header">${this.#$()}</div>
          <div class='dialog-content'>
            <slot></slot>
          </div>
    </div>
    `),v.render(C`
      <style>${gt}</style>
      <dialog @click=${this.#b} @pointermove=${this.#b} @cancel=${this.#B} @animationend=${this.#w}
              jslog=${D.dialog(this.#t.jslogContext).track({resize:!0,keydown:"Escape"}).parent("mapped")}>
        ${t}
      </dialog>
    `,this.#d,{host:this}),D.setMappedParent(this.#l(),this.parentElementOrShadowHost())}setBoundingElementForTesting(t){this.#h=t,this.#i()}};customElements.define("devtools-dialog",$);var O=class i extends Event{static eventName="pointerleftdialog";constructor(){super(i.eventName,{bubbles:!0,composed:!0})}},R=class i extends Event{static eventName="clickoutsidedialog";constructor(){super(i.eventName,{bubbles:!0,composed:!0})}},I=class i extends Event{static eventName="animationended";constructor(){super(i.eventName,{bubbles:!0,composed:!0})}},f=class i extends Event{static eventName="forceddialogclose";constructor(){super(i.eventName,{bubbles:!0,composed:!0})}},Q=(o=>(o.TOP="top",o.BOTTOM="bottom",o.AUTO="auto",o))(Q||{}),Z=(o=>(o.EXPANDED="expanded",o.COLLAPSED="collapsed",o.DISABLED="disabled",o))(Z||{}),M=(n=>(n.LEFT="left",n.RIGHT="right",n.CENTER="center",n.AUTO="auto",n))(M||{});var{ref:ft}=Ht,k=class extends HTMLElement{#d=this.attachShadow({mode:"open"});#e=null;#s=null;#t=null;set data(t){this.#t=t,w.ScheduledRender.scheduleRender(this,this.#r)}#o(){if(!this.#e)throw new Error("Dialog not found");this.#t?.state==="disabled"?this.#e.setDialogVisible(!1):this.#e.setDialogVisible(!0),w.ScheduledRender.scheduleRender(this,this.#r)}#n(t){if(!this.#e)throw new Error("Dialog not found");this.#e.setDialogVisible(!1),t&&t.stopImmediatePropagation(),w.ScheduledRender.scheduleRender(this,this.#r)}set state(t){this.#t&&(this.#t.state=t,w.ScheduledRender.scheduleRender(this,this.#r))}#r(){if(!this.#t)throw new Error("ButtonDialog.data is not set");if(!w.ScheduledRender.isScheduledRender(this))throw new Error("Button dialog render was not scheduled");Vt(Ut`
      <style>${ct}</style>
      <devtools-button
        @click=${this.#o}
        ${ft(t=>{t instanceof HTMLElement&&(this.#s=t)})}
        .data=${{variant:this.#t.variant,iconName:this.#t.iconName,disabled:this.#t.disabled,title:this.#t.iconTitle,jslogContext:this.#t.jslogContext}}
      ></devtools-button>
      <devtools-dialog
        @clickoutsidedialog=${this.#n}
        .origin=${()=>{if(!this.#s)throw new Error("Button not found");return this.#s}}
        .position=${this.#t.position??"bottom"}
        .horizontalAlignment=${this.#t.horizontalAlignment??"right"}
        .closeOnESC=${this.#t.closeOnESC??!1}
        .closeOnScroll=${this.#t.closeOnScroll??!1}
        .closeButton=${this.#t.closeButton??!1}
        .dialogTitle=${this.#t.dialogTitle}
        .jslogContext=${this.#t.jslogContext??""}
        .state=${this.#t.state??"expanded"}
        ${ft(t=>{t instanceof HTMLElement&&(this.#e=t)})}
      >
        <slot></slot>
      </devtools-dialog>
      `,this.#d,{host:this}),this.#t.openOnRender&&(this.#o(),this.#t.openOnRender=!1)}};customElements.define("devtools-button-dialog",k);var Dt={};E(Dt,{FreDialog:()=>tt});import*as et from"../../../core/i18n/i18n.js";import*as U from"../../legacy/legacy.js";import*as ot from"../../lit/lit.js";import*as H from"../buttons/buttons.js";var yt=`.fre-disclaimer{overflow-y:auto;width:var(--sys-size-33);padding:var(--sys-size-9);header{display:flex;gap:var(--sys-size-8);margin-bottom:var(--sys-size-6);align-items:center;h2{margin:0;color:var(--sys-color-on-surface);font:var(--sys-typescale-headline5)}.header-icon-container{background:linear-gradient(135deg,var(--sys-color-gradient-primary),var(--sys-color-gradient-tertiary));border-radius:var(--sys-size-4);min-height:var(--sys-size-14);min-width:var(--sys-size-14);display:flex;align-items:center;justify-content:center;devtools-icon{width:var(--sys-size-9);height:var(--sys-size-9)}}}.reminder-container{border-radius:var(--sys-size-6);background-color:var(--sys-color-surface4);padding:var(--sys-size-9);h3{color:var(--sys-color-on-surface);font:var(--sys-typescale-body4-medium);margin:0}.reminder-item{display:flex;flex-direction:row;align-items:center;gap:var(--sys-size-5);margin-top:var(--sys-size-6);font:var(--sys-typescale-body5-regular);devtools-icon.reminder-icon{width:var(--sys-size-8);height:var(--sys-size-8)}.link{color:var(--sys-color-primary);text-decoration-line:underline}}}footer{display:flex;flex-direction:row;align-items:center;justify-content:space-between;margin-top:var(--sys-size-8);min-width:var(--sys-size-28);.right-buttons{display:flex;gap:var(--sys-size-5)}}}
/*# sourceURL=${import.meta.resolve("./freDialog.css")} */`;var{html:bt,Directives:{ifDefined:Nt}}=ot,x={thingsToConsider:"Things to consider",learnMore:"Learn more",cancel:"Cancel",gotIt:"Got it"},jt=et.i18n.registerUIStrings("ui/components/dialogs/FreDialog.ts",x),A=et.i18n.getLocalizedString.bind(void 0,jt),tt=class{static show({header:t,reminderItems:e,onLearnMoreClick:o,ariaLabel:n,learnMoreButtonText:c,learnMoreButtonAriaLabel:a}){let s=new U.Dialog.Dialog;n&&s.setAriaLabel(n),s.contentElement.tabIndex=-1;let l=Promise.withResolvers();return ot.render(bt`
      <div class="fre-disclaimer">
        <style>
          ${yt}
        </style>
        <header>
          <div class="header-icon-container">
            <devtools-icon name=${t.iconName}></devtools-icon>
          </div>
          <h2 tabindex="-1">
            ${t.text}
          </h2>
        </header>
        <main class="reminder-container">
          <h3>${A(x.thingsToConsider)}</h3>
          ${e.map(r=>bt`
            <div class="reminder-item">
              <devtools-icon class="reminder-icon" name=${r.iconName}></devtools-icon>
              <span>${r.content}</span>
            </div>
          `)}
        </main>
        <footer>
          <devtools-button
            @click=${o}
            .jslogContext=${"fre-disclaimer.learn-more"}
            .variant=${H.Button.Variant.OUTLINED}
            .title=${a??A(x.learnMore)}
            aria-label=${Nt(a)}>
            ${c??A(x.learnMore)}
          </devtools-button>
          <div class="right-buttons">
            <devtools-button
              @click=${()=>{l.resolve(!1),s.hide()}}
              .jslogContext=${"fre-disclaimer.cancel"}
              .variant=${H.Button.Variant.TONAL}>
              ${A(x.cancel)}
            </devtools-button>
            <devtools-button
              @click=${()=>{l.resolve(!0),s.hide()}}
              .jslogContext=${"fre-disclaimer.continue"}
              .variant=${H.Button.Variant.PRIMARY}>
              ${A(x.gotIt)}
            </devtools-button>
          </div>
        </footer>
      </div>`,s.contentElement),s.setOutsideClickCallback(r=>{r.consume(!0),s.hide(),l.resolve(!1)}),s.setOnHideCallback(()=>{l.resolve(!1)}),s.setSizeBehavior(U.GlassPane.SizeBehavior.MEASURE_CONTENT),s.setDimmed(!0),s.show(),s.contentElement.focus(),l.promise}constructor(){}};var Tt={};E(Tt,{ShortcutDialog:()=>V});import*as nt from"../../../core/i18n/i18n.js";import*as St from"../buttons/buttons.js";import*as it from"../helpers/helpers.js";import{html as h,nothing as Wt,render as Xt}from"../../lit/lit.js";var wt=`.keybinds-list{display:flex;flex-direction:column;margin:0;padding:0}.keybinds-list-item{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:flex-start;min-width:min(315px,calc(var(--dialog-max-width, 1000px) - var(--sys-size-13)));gap:var(--sys-size-4);border-bottom:var(--sys-size-1) solid var(--sys-color-divider);padding:var(--sys-size-4) 0;&:last-of-type{border-bottom:unset}.keybinds-list-title{display:flex;align-items:center;min-height:var(--sys-size-11);white-space:normal;overflow-wrap:break-word;flex:1 1 120px}}.row-container{display:flex;gap:var(--sys-size-5);align-items:center;flex-wrap:wrap;justify-content:flex-end;.keybinds-join-text, .footnote{color:var(--sys-color-on-surface-subtle)}.footnote{display:block;height:15px}}.shortcuts-for-actions{display:flex;flex-direction:column;align-items:flex-end;gap:var(--sys-size-3);max-width:100%}.nav-radio-buttons{display:flex;flex-direction:column;border-bottom:var(--sys-size-1) solid var(--sys-color-divider);padding-bottom:var(--sys-size-5);& label{display:flex;font:var(--sys-typescale-body3-regular);gap:var(--sys-size-2)}input[type="radio"]{margin-left:0}}.keybinds-key{display:flex;align-items:center;justify-content:center;box-sizing:border-box;padding:var(--sys-size-4);min-width:var(--sys-size-11);height:var(--sys-size-11);font:var(--sys-typescale-body5-medium);white-space:nowrap;border-radius:var(--sys-shape-corner-small);background:var(--sys-color-base-container)}
/*# sourceURL=${import.meta.resolve("./shortcutDialog.css")} */`;var st={showShortcutTitle:"Show shortcuts",dialogTitle:"Keyboard shortcuts"},_t=nt.i18n.registerUIStrings("ui/components/dialogs/ShortcutDialog.ts",st),xt=nt.i18n.getLocalizedString.bind(void 0,_t),V=class extends HTMLElement{#d=this.attachShadow({mode:"open"});#e=[];#s=!1;#t;#o=null;get data(){return{shortcuts:this.#e,open:this.#s,customTitle:this.#t}}set data(t){this.#e=t.shortcuts,t.open&&(this.#s=t.open),t.customTitle&&(this.#t=t.customTitle),it.ScheduledRender.scheduleRender(this,this.#r)}prependElement(t){this.#o=t}#n(t){return Array.isArray(t)?h`${t.map(e=>"key"in e?h`<span class="keybinds-key">${e.key}</span>`:h`<span class="keybinds-join-text">${e.joinText}</span>`)}
    `:h`<span class="footnote">${t.footnote}</span>`}#r(){if(!it.ScheduledRender.isScheduledRender(this))throw new Error("Shortcut dialog render was not scheduled");Xt(h`
      <style>${wt}</style>
      <devtools-button-dialog .data=${{openOnRender:this.#s,closeButton:!0,dialogTitle:this.#t??xt(st.dialogTitle),variant:St.Button.Variant.TOOLBAR,iconName:"help",iconTitle:xt(st.showShortcutTitle),horizontalAlignment:"auto"}}>
        <ul class="keybinds-list">
          ${this.#o?h`${this.#o}`:Wt}
          ${this.#e.map(t=>h`
              <li class="keybinds-list-item">
                <div class="keybinds-list-title">${t.title}</div>
                <div class="shortcuts-for-actions">
                  ${t.rows.map(e=>h`<div class="row-container">${this.#n(e)}</div>
                  `)}
                </div>
              </li>`)}
        </ul>
      </devtools-button-dialog>
      `,this.#d,{host:this})}};customElements.define("devtools-shortcut-dialog",V);var At={};E(At,{TypeToAllowDialog:()=>at});import*as j from"../../../core/host/host.js";import*as lt from"../../../core/i18n/i18n.js";import*as N from"../buttons/buttons.js";import*as y from"../../legacy/legacy.js";import*as Pt from"../../geometry/geometry.js";import*as dt from"../../lit/lit.js";import*as zt from"../../visual_logging/visual_logging.js";var Et=`.type-to-allow-dialog{width:100%;.header{display:flex;justify-content:space-between;font:var(--sys-typescale-body2-medium);margin:var(--sys-size-5) var(--sys-size-5) var(--sys-size-5) var(--sys-size-8)}.title{padding-top:var(--sys-size-3)}.dialog-close-button{margin:var(--sys-size-3);z-index:1}.message,
  .text-input{margin:0 var(--sys-size-8)}.text-input{margin-top:var(--sys-size-5)}.button{text-align:right;margin:var(--sys-size-6) var(--sys-size-8) var(--sys-size-8) var(--sys-size-8);gap:var(--sys-size-5);display:flex;flex-direction:row-reverse;justify-content:flex-start}.button button{min-width:var(--sys-size-19)}}
/*# sourceURL=${import.meta.resolve("./typeToAllowDialog.css")} */`;var{html:Gt,Directives:{ref:Ft}}=dt,rt={cancel:"Cancel",allow:"Allow"},Yt=lt.i18n.registerUIStrings("ui/components/dialogs/TypeToAllowDialog.ts",rt),Ct=lt.i18n.getLocalizedString.bind(void 0,Yt),Kt=(i,t,e)=>{dt.render(Gt`
    <div class="type-to-allow-dialog">
      <div class="header">
        <div class="title">${i.header}</div>
        <dt-close-button
          class="dialog-close-button"
          ${Ft(o=>{o instanceof y.UIUtils.DevToolsCloseButton&&(o.setTabbable(!0),o.setSize(N.Button.Size.SMALL))})}
          @click=${i.onClose}
        ></dt-close-button>
      </div>
      <div class="message">${i.message}</div>
      <input
        class="harmony-input text-input"
        type="text"
        placeholder=${i.inputPlaceholder}
        jslog=${zt.textField().track({keydown:"ArrowUp|ArrowDown|PageUp|PageDown|Enter|Tab",change:!0}).context(i.inputJslogContext)}
        @input=${o=>i.onInput(o.target.value)}
        @paste=${o=>o.preventDefault()}
        @drop=${o=>o.preventDefault()}
      >
      <div class="button">
        <devtools-button
          class="text-button"
          .variant=${N.Button.Variant.PRIMARY}
          .jslogContext=${"confirm"}
          .disabled=${i.allowDisabled}
          @click=${i.onAllow}
        >${Ct(rt.allow)}</devtools-button>
        <devtools-button
          class="text-button"
          .variant=${N.Button.Variant.OUTLINED}
          .jslogContext=${"cancel"}
          @click=${i.onCancel}
        >${Ct(rt.cancel)}</devtools-button>
      </div>
    </div>
  `,e)},at=class{static async show(t,e=Kt){let o=new y.Dialog.Dialog(t.jslogContext.dialog);o.setMaxContentSize(new Pt.Size(504,340)),o.setSizeBehavior(y.GlassPane.SizeBehavior.SET_EXACT_WIDTH_MAX_HEIGHT),o.setDimmed(!0);let n=y.UIUtils.createShadowRootWithCoreStyles(o.contentElement,{cssFile:Et}),c=await new Promise(a=>{let s="",l=()=>{e({header:t.header,message:t.message,inputPlaceholder:t.inputPlaceholder,inputJslogContext:t.jslogContext.input,allowDisabled:!s,onInput:r=>{s=r,l()},onClose:r=>{o.hide(),r.consume(!0),a(!1)},onAllow:()=>{a(s===t.typePhrase||s===`'${t.typePhrase}'`)},onCancel:()=>{a(!1)}},void 0,n)};l(),o.setOutsideClickCallback(r=>{r.consume(),a(!1)}),o.show(),j.userMetrics.actionTaken(j.UserMetrics.Action.SelfXssWarningDialogShown)});return o.hide(),c}};export{vt as ButtonDialog,mt as Dialog,Dt as FreDialog,Tt as ShortcutDialog,At as TypeToAllowDialog};
//# sourceMappingURL=dialogs.js.map
