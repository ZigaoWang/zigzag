var we=Object.defineProperty;var R=(i,e)=>{for(var t in e)we(i,t,{get:e[t],enumerable:!0})};var Y={};R(Y,{EntriesLinkOverlay:()=>N,EntryLinkStartCreating:()=>I});import"../../../../ui/kit/kit.js";import*as G from"../../../../core/i18n/i18n.js";import*as C from"../../../../models/trace/trace.js";import*as B from"../../../../ui/legacy/theme_support/theme_support.js";import{html as xe,render as Ee}from"../../../../ui/lit/lit.js";import*as K from"../../../../ui/visual_logging/visual_logging.js";var P=`.connectorContainer{display:flex;width:100%;height:100%}.entry-wrapper{pointer-events:none;position:absolute;display:block;border:var(--sys-size-2) solid var(--sys-color-on-surface);box-sizing:border-box;&.cut-off-top{border-top:none}&.cut-off-bottom{border-bottom:none}&.cut-off-right{border-right:none}&.cut-off-left{border-left:none}}.entry-is-not-source{border:var(--sys-size-2) dashed var(--sys-color-on-surface)}.create-link-icon{pointer-events:auto;cursor:pointer;color:var(--sys-color-on-surface);width:var(--sys-size-8);height:var(--sys-size-8);position:absolute}
/*# sourceURL=${import.meta.resolve("./entriesLinkOverlay.css")} */`;var X={diagram:"Links between entries"},Te=G.i18n.registerUIStrings("panels/timeline/overlays/components/EntriesLinkOverlay.ts",X),Ae=G.i18n.getLocalizedString.bind(void 0,Te),I=class i extends Event{static eventName="entrylinkstartcreating";constructor(){super(i.eventName,{bubbles:!0,composed:!0})}},N=class extends HTMLElement{#i=this.attachShadow({mode:"open"});#n;#t;#s;#o=null;#d=null;#e=null;#r=null;#a=null;#l=null;#b=null;#h=!0;#c=!0;#f=null;#y=!0;#p=!0;#u=!1;#v;constructor(e,t){super(),this.#m(),this.#n={x:e.x,y:e.y},this.#t={width:e.width,height:e.height},this.#s={x:e.x,y:e.y},this.#d=this.#i.querySelector(".connectorContainer")??null,this.#e=this.#d?.querySelector("line")??null,this.#r=this.#i.querySelector(".from-highlight-wrapper")??null,this.#a=this.#i.querySelector(".to-highlight-wrapper")??null,this.#l=this.#d?.querySelector(".entryFromConnector")??null,this.#b=this.#d?.querySelector(".entryToConnector")??null,this.#v=t,this.#m()}set canvasRect(e){e!==null&&(this.#f&&this.#f.width===e.width&&this.#f.height===e.height||(this.#f=e,this.#m()))}entryFromWrapper(){return this.#r}entryToWrapper(){return this.#a}set hideArrow(e){this.#u=e,this.#e&&(this.#e.style.display=e?"none":"block")}set fromEntryCoordinateAndDimensions(e){this.#n={x:e.x,y:e.y},this.#t={width:e.length,height:e.height},this.#w(),this.#x()}set entriesVisibility(e){this.#h=e.fromEntryVisibility,this.#c=e.toEntryVisibility,this.#x()}set toEntryCoordinateAndDimensions(e){this.#s={x:e.x,y:e.y},e.length&&e.height?this.#o={width:e.length,height:e.height}:this.#o=null,this.#w(),this.#x()}set fromEntryIsSource(e){e!==this.#y&&(this.#y=e,this.#m())}set toEntryIsSource(e){e!==this.#p&&(this.#p=e,this.#m())}#x(){if(!this.#e||!this.#r||!this.#a||!this.#l||!this.#b){console.error("one of the required Entries Link elements is missing.");return}if(this.#v===C.Types.File.EntriesLinkState.CREATION_NOT_STARTED){this.#l.setAttribute("visibility","hidden"),this.#b.setAttribute("visibility","hidden"),this.#e.style.display="none";return}this.#S(),this.#T(),this.#A(),this.#E(),this.#m()}#S(){!this.#r||!this.#a||(this.#r.style.visibility=this.#h?"visible":"hidden",this.#a.style.visibility=this.#c?"visible":"hidden")}#T(){if(!this.#o||!this.#l||!this.#b)return;let e=8,t=this.#h&&!this.#u&&this.#y&&this.#t.width>=e,n=!this.#u&&this.#c&&this.#p&&this.#o?.width>=e&&!this.#u;this.#l.setAttribute("visibility",t?"visible":"hidden"),this.#b.setAttribute("visibility",n?"visible":"hidden")}#A(){if(!this.#e)return;this.#e.style.display=this.#h||this.#c?"block":"none",this.#e.setAttribute("stroke-width","2");let e=B.ThemeSupport.instance().getComputedValue("--color-text-primary");if(!this.#o||this.#h&&this.#c){this.#e.setAttribute("stroke",e);return}this.#h&&!this.#c?this.#e.setAttribute("stroke","url(#fromVisibleLineGradient)"):this.#c&&!this.#h&&this.#e.setAttribute("stroke","url(#toVisibleLineGradient)")}#E(){if(!this.#e||!this.#l||!this.#b)return;let e=this.#t.height/2,t=this.#n.x+this.#t.width,n=this.#n.y+e;this.#e.setAttribute("x1",t.toString()),this.#e.setAttribute("y1",n.toString()),this.#l.setAttribute("cx",t.toString()),this.#l.setAttribute("cy",n.toString());let o=this.#s.x,r=this.#o?this.#s.y+(this.#o?.height??0)/2:this.#s.y;this.#e.setAttribute("x2",o.toString()),this.#e.setAttribute("y2",r.toString()),this.#b.setAttribute("cx",o.toString()),this.#b.setAttribute("cy",r.toString())}#L(){if(!this.#f)return 100;let e=25,t=this.#s.x-(this.#n.x+this.#t.width),n=e*100/t;return n<100?n:100}#w(){let e=this.#i.querySelector(".create-link-box"),t=e?.querySelector(".create-link-icon")??null;if(!e||!t){console.error("creating element is missing.");return}if(this.#v!==C.Types.File.EntriesLinkState.CREATION_NOT_STARTED){t.style.display="none";return}t.style.left=`${this.#n.x+this.#t.width}px`,t.style.top=`${this.#n.y}px`}#k(){this.#v=C.Types.File.EntriesLinkState.PENDING_TO_EVENT,this.dispatchEvent(new I)}#m(){let e=B.ThemeSupport.instance().getComputedValue("--color-text-primary");Ee(xe`
          <style>${P}</style>
          <svg class="connectorContainer" width="100%" height="100%" role="region" aria-label=${Ae(X.diagram)}>
            <defs>
              <linearGradient
                id="fromVisibleLineGradient"
                x1="0%" y1="0%" x2="100%" y2="0%">
                <stop
                  offset="0%"
                  stop-color=${e}
                  stop-opacity="1" />
                <stop
                  offset="${this.#L()}%"
                  stop-color=${e}
                  stop-opacity="0" />
              </linearGradient>

              <linearGradient
                id="toVisibleLineGradient"
                x1="0%" y1="0%" x2="100%" y2="0%">
                <stop
                  offset="${100-this.#L()}%"
                  stop-color=${e}
                  stop-opacity="0" />
                <stop
                  offset="100%"
                  stop-color=${e}
                  stop-opacity="1" />
              </linearGradient>
              <marker
                id="arrow"
                orient="auto"
                markerWidth="3"
                markerHeight="4"
                fill-opacity="1"
                refX="4"
                refY="2"
                visibility=${this.#c||!this.#o?"visible":"hidden"}>
                <path d="M0,0 V4 L4,2 Z" fill=${e} />
              </marker>
            </defs>
            <line
              marker-end="url(#arrow)"
              stroke-dasharray=${!this.#y||!this.#p?Se:"none"}
              visibility=${!this.#h&&!this.#c?"hidden":"visible"}
              />
            <circle class="entryFromConnector" fill="none" stroke=${e} stroke-width=${W} r=${q} />
            <circle class="entryToConnector" fill="none" stroke=${e} stroke-width=${W} r=${q} />
          </svg>
          <div class="entry-wrapper from-highlight-wrapper ${this.#y?"":"entry-is-not-source"}"></div>
          <div class="entry-wrapper to-highlight-wrapper ${this.#p?"":"entry-is-not-source"}"></div>
          <div class="create-link-box ${this.#v?"visible":"hidden"}">
            <devtools-icon
              class='create-link-icon'
              jslog=${K.action("timeline.annotations.create-entry-link").track({click:!0})}
              @click=${this.#k}
              name='arrow-right-circle'>
            </devtools-icon>
          </div>
        `,this.#i,{host:this})}},q=2,W=1,Se=4;customElements.define("devtools-entries-link-overlay",N);var oe={};R(oe,{EntryLabelChangeEvent:()=>T,EntryLabelOverlay:()=>D,EntryLabelRemoveEvent:()=>E,LabelAnnotationsConsentDialogVisibilityChange:()=>A});import"../../../../ui/kit/kit.js";import"../../../../ui/components/tooltips/tooltips.js";import"../../../../ui/components/spinners/spinners.js";import*as J from"../../../../core/common/common.js";import*as Q from"../../../../core/host/host.js";import*as H from"../../../../core/i18n/i18n.js";import*as V from"../../../../core/platform/platform.js";import*as h from"../../../../core/root/root.js";import*as ee from"../../../../models/ai_assistance/ai_assistance.js";import*as te from"../../../../ui/components/buttons/buttons.js";import*as ie from"../../../../ui/components/dialogs/dialogs.js";import*as $ from"../../../../ui/components/helpers/helpers.js";import*as ne from"../../../../ui/helpers/helpers.js";import*as O from"../../../../ui/legacy/legacy.js";import*as se from"../../../../ui/legacy/theme_support/theme_support.js";import*as b from"../../../../ui/lit/lit.js";import*as f from"../../../../ui/visual_logging/visual_logging.js";var j=`.label-parts-wrapper{display:flex;flex-direction:column;align-items:center}.label-button-input-wrapper{display:flex;position:relative;overflow:visible}.ai-label-button-wrapper,
.ai-label-disabled-button-wrapper,
.ai-label-loading,
.ai-label-error{position:absolute;left:100%;display:flex;transform:translateY(-3px);flex-flow:row nowrap;border:none;border-radius:var(--sys-shape-corner-large);background:var(--sys-color-surface3);box-shadow:var(--drop-shadow);align-items:center;gap:var(--sys-size-4);pointer-events:auto;transition:all var(--sys-motion-duration-medium2) var(--sys-motion-easing-emphasized);&.only-pen-wrapper{overflow:hidden;width:var(--sys-size-12);height:var(--sys-size-12)}*{transform:translateX(-2px)}}.delete-button{display:flex;pointer-events:auto;position:absolute;right:0;top:-5px;border-radius:50%;padding:0;border:none;background:var(--sys-color-inverse-surface)}.ai-label-loading,
.ai-label-error{gap:var(--sys-size-6);padding:var(--sys-size-5) var(--sys-size-8)}.ai-label-button-wrapper:focus,
.ai-label-button-wrapper:focus-within,
.ai-label-button-wrapper:hover{width:auto;height:var(--sys-size-13);padding:var(--sys-size-3) var(--sys-size-5);transform:translateY(-9px);*{transform:translateX(0)}}.ai-label-button{display:flex;align-items:center;gap:var(--sys-size-4);padding:var(--sys-size-3) var(--sys-size-5);border:var(--sys-size-1) solid var(--sys-color-primary);border-radius:var(--sys-shape-corner-large);&.enabled{background:var(--sys-color-surface3)}&.disabled{background:var(--sys-color-surface5)}&:hover{background:var(--sys-color-state-hover-on-subtle)}}.generate-label-text{white-space:nowrap;color:var(--sys-color-primary)}.input-field{background-color:var(--sys-color-inverse-surface);color:var(--sys-color-cdt-base-container);pointer-events:auto;border-radius:var(--sys-shape-corner-extra-small);white-space:nowrap;padding:var(--sys-size-3) var(--sys-size-4);font-family:var(--default-font-family);font-size:var(--sys-typescale-body2-size);font-weight:var(--ref-typeface-weight-medium);outline:var(--sys-size-2) solid var(--sys-color-cdt-base-container)}.input-field:focus,
.label-parts-wrapper:focus-within .input-field,
.input-field.fake-focus-state{background-color:var(--sys-color-cdt-base-container);color:var(--sys-color-inverse-surface);outline:var(--sys-size-2) solid var(--sys-color-inverse-surface)}.connectorContainer{overflow:visible}.entry-highlight-wrapper{box-sizing:border-box;border:var(--sys-size-2) solid var(--sys-color-on-surface);&.cut-off-top{border-top:none}&.cut-off-bottom{border-bottom:none}&.cut-off-right{border-right:none}&.cut-off-left{border-left:none}}.info-tooltip-container{max-width:var(--sys-size-28);button.link{cursor:pointer;text-decoration:underline;border:none;padding:0;background:none;font:inherit;font-weight:var(--ref-typeface-weight-medium);display:block;margin-top:var(--sys-size-4);color:var(--sys-color-primary)}}
/*# sourceURL=${import.meta.resolve("./entryLabelOverlay.css")} */`;var{html:p,Directives:Z}=b,m={entryLabel:"Entry label",inputTextPrompt:"Enter an annotation label",generateLabelButton:"Generate label",freDialog:"Get AI-powered annotation suggestions dialog",learnMoreAriaLabel:"Learn more about auto annotations in settings",moreInfoAriaLabel:"More information about this feature"},c={learnMore:"Learn more in settings",generateLabelSecurityDisclaimer:"The selected call stack is sent to Google. This data may be seen by human reviewers to improve this feature. This is an experimental AI feature and won\u2019t always get it right.",generateLabelSecurityDisclaimerLoggingOff:"The selected call stack is sent to Google. This data won\u2019t be used to improve Google\u2019s AI models. Your organization may change these settings at any time. This is an experimental AI feature and won\u2019t always get it right.",autoAnnotationNotAvailableDisclaimer:"Auto annotations aren\u2019t available.",autoAnnotationNotAvailableOfflineDisclaimer:"Auto annotations aren\u2019t available because you are offline",freDisclaimerHeader:"Get AI-powered annotation suggestions",generatingLabel:"Generating label",generationFailed:"Generation failed",freDisclaimerAiWontAlwaysGetItRight:"This feature uses AI and won\u2019t always get it right",freDisclaimerPrivacyDataSentToGoogle:"To generate annotation suggestions, your performance trace is sent to Google. This data may be seen by human reviewers to improve this feature.",freDisclaimerPrivacyDataSentToGoogleNoLogging:"To generate annotation suggestions, your performance trace is sent to Google. This data won\u2019t be used to improve Google\u2019s AI models. Your organization may change these settings at any time.",learnMoreButton:"Learn more"};var ke=H.i18n.registerUIStrings("panels/timeline/overlays/components/EntryLabelOverlay.ts",m),L=H.i18n.getLocalizedString.bind(void 0,ke),d=H.i18n.lockedString;function Re(){return h.Runtime.hostConfig.devToolsGeminiRebranding?.enabled?!1:!h.Runtime.hostConfig.aidaAvailability?.disallowLogging}var E=class i extends Event{static eventName="entrylabelremoveevent";constructor(){super(i.eventName)}},T=class i extends Event{constructor(t){super(i.eventName);this.newLabel=t}newLabel;static eventName="entrylabelchangeevent"},A=class i extends Event{constructor(t){super(i.eventName,{bubbles:!0,composed:!0});this.isVisible=t}isVisible;static eventName="labelannotationsconsentdialogvisiblitychange"},D=class i extends HTMLElement{static LABEL_AND_CONNECTOR_SHIFT_LENGTH=8;static LABEL_CONNECTOR_HEIGHT=7;static MAX_LABEL_LENGTH=100;#i=this.attachShadow({mode:"open"});#n=!1;#t=!0;#s=null;#o=null;#d=null;#e=null;#r=null;#a;#l;#b=Z.createRef();#h;#c=null;#f=J.Settings.Settings.instance().createSetting("ai-annotations-enabled",!1);#y=new ee.PerformanceAnnotations.PerformanceAnnotations({aidaClient:new Q.AidaClient.AidaClient,serverSideLoggingEnabled:Re()});#p=!1;#u="hidden";constructor(e,t=!1){super(),this.#g(),this.#l=t,this.#o=this.#i.querySelector(".label-parts-wrapper"),this.#e=this.#o?.querySelector(".input-field")??null,this.#r=this.#o?.querySelector(".connectorContainer")??null,this.#d=this.#o?.querySelector(".entry-highlight-wrapper")??null,this.#a=e,this.#h=h.Runtime.hostConfig.aidaAvailability?.enterprisePolicyValue===h.Runtime.GenAiEnterprisePolicyValue.ALLOW_WITHOUT_LOGGING,this.#A(e),e!==""&&this.setLabelEditabilityAndRemoveEmptyLabel(!1);let n=e===""?L(m.inputTextPrompt):e;this.#e?.setAttribute("aria-label",n),this.#T()}overridePerformanceAnnotationsForTest(e){this.#y=e}entryHighlightWrapper(){return this.#d}#v(){let e=this.#e?.textContent?.trim()??"";e!==this.#a&&(this.#a=e,this.dispatchEvent(new T(this.#a)),this.#e?.dispatchEvent(new Event("change",{bubbles:!0,composed:!0}))),this.#m(),this.#g(),this.#e?.setAttribute("aria-label",e)}#x(e){if(!this.#e)return!1;let t=["Backspace","Delete","ArrowLeft","ArrowRight"];return(e.key===V.KeyboardUtilities.ENTER_KEY||e.key===V.KeyboardUtilities.ESCAPE_KEY)&&this.#t?(this.#e.blur(),this.setLabelEditabilityAndRemoveEmptyLabel(!1),!1):this.#e.textContent!==null&&this.#e.textContent.length<=i.MAX_LABEL_LENGTH||t.includes(e.key)||e.key.length===1&&e.ctrlKey?!0:(e.preventDefault(),!1)}#S(e){e.preventDefault();let t=e.clipboardData;if(!t||!this.#e)return;let n=t.getData("text").replace(/(\r\n|\n|\r)/gm,""),r=(this.#e.textContent+n).slice(0,i.MAX_LABEL_LENGTH+1);this.#e.textContent=r,this.#L()}set entryLabelVisibleHeight(e){this.#s=e,$.ScheduledRender.scheduleRender(this,this.#g),this.#t&&this.#E(),this.#A(),this.#T()}#T(){if(!this.#r){console.error("`connectorLineContainer` element is missing.");return}if(this.#l&&this.#s){let o=this.#s+i.LABEL_CONNECTOR_HEIGHT;this.#r.style.transform=`translateY(${o}px) rotate(180deg)`}let e=this.#r.querySelector("line"),t=this.#r.querySelector("circle");if(!e||!t){console.error("Some entry label elements are missing.");return}this.#r.setAttribute("width",(i.LABEL_AND_CONNECTOR_SHIFT_LENGTH*2).toString()),this.#r.setAttribute("height",i.LABEL_CONNECTOR_HEIGHT.toString()),e.setAttribute("x1","0"),e.setAttribute("y1","0"),e.setAttribute("x2",i.LABEL_AND_CONNECTOR_SHIFT_LENGTH.toString()),e.setAttribute("y2",i.LABEL_CONNECTOR_HEIGHT.toString());let n=se.ThemeSupport.instance().getComputedValue("--color-text-primary");e.setAttribute("stroke",n),e.setAttribute("stroke-width","2"),t.setAttribute("cx",i.LABEL_AND_CONNECTOR_SHIFT_LENGTH.toString()),t.setAttribute("cy",(i.LABEL_CONNECTOR_HEIGHT+1).toString()),t.setAttribute("r","3"),t.setAttribute("fill",n)}#A(e){if(!this.#e){console.error("`labelBox`element is missing.");return}typeof e=="string"&&(this.#e.innerText=e);let t=null,n=null;this.#l?t=i.LABEL_AND_CONNECTOR_SHIFT_LENGTH:t=i.LABEL_AND_CONNECTOR_SHIFT_LENGTH*-1,this.#l&&this.#s&&(n=this.#s+i.LABEL_CONNECTOR_HEIGHT*2+this.#e?.offsetHeight);let o="";t&&(o+=`translateX(${t}px) `),n&&(o+=`translateY(${n}px)`),o.length&&(this.#e.style.transform=o)}#E(){if(!this.#e){console.error("`labelBox` element is missing.");return}this.#e.focus()}setLabelEditabilityAndRemoveEmptyLabel(e){if(this.#p&&e===!1)return;e?this.setAttribute("data-user-editing-label","true"):this.removeAttribute("data-user-editing-label"),this.#t=e,this.#g(),e&&this.#e&&(this.#L(),this.#E());let t=this.#e?.textContent?.trim()??"";!e&&t.length===0&&!this.#n&&(this.#n=!0,this.dispatchEvent(new E))}#L(){if(!this.#e)return;let e=window.getSelection(),t=document.createRange();t.selectNodeContents(this.#e),t.collapse(!1),e?.removeAllRanges(),e?.addRange(t)}set callTree(e){this.#c=e,this.#m()}async#w(){if(this.#f.get()){if(!this.#c||!this.#e)return;try{this.#u="generating_label",O.ARIAUtils.LiveAnnouncer.alert(c.generatingLabel),this.#g(),this.#E(),$.ScheduledRender.scheduleRender(this,this.#g),this.#a=await this.#y.generateAIEntryLabel(this.#c),this.dispatchEvent(new T(this.#a)),this.#e.innerText=this.#a,this.#L(),this.#m(),this.#g()}catch{this.#u="generation_failed",$.ScheduledRender.scheduleRender(this,this.#g)}}else{this.#p=!0,this.#g();let e=await this.#k();this.#p=!1,this.setLabelEditabilityAndRemoveEmptyLabel(!0),e&&await this.#w()}}async#k(){this.dispatchEvent(new A(!0));let e=await ie.FreDialog.FreDialog.show({ariaLabel:L(m.freDialog),header:{iconName:"pen-spark",text:d(c.freDisclaimerHeader)},reminderItems:[{iconName:"psychiatry",content:d(c.freDisclaimerAiWontAlwaysGetItRight)},{iconName:"google",content:this.#h?d(c.freDisclaimerPrivacyDataSentToGoogleNoLogging):d(c.freDisclaimerPrivacyDataSentToGoogle)}],onLearnMoreClick:()=>{ne.openInNewTab("https://developer.chrome.com/docs/devtools/performance/annotations#auto-annotations")},learnMoreButtonText:c.learnMoreButton});return this.dispatchEvent(new A(!1)),e&&this.#f.set(!0),this.#f.get()}#m(){let e=!!h.Runtime.hostConfig.devToolsAiGeneratedTimelineLabels?.enabled,t=h.Runtime.hostConfig.aidaAvailability?.enterprisePolicyValue===h.Runtime.GenAiEnterprisePolicyValue.DISABLE,n=this.#c!==null,o=this.#a?.length<=0;!e||t||!n||!o?this.#u="hidden":h.Runtime.hostConfig.aidaAvailability?.enabled&&!h.Runtime.hostConfig.aidaAvailability?.blockedByAge&&!h.Runtime.hostConfig.aidaAvailability?.blockedByGeo&&navigator.onLine?this.#u="enabled":this.#u="disabled"}#R(e){return p`<devtools-tooltip
    variant="rich"
    id="info-tooltip"
    ${Z.ref(this.#b)}>
      <div class="info-tooltip-container">
        ${e.textContent} ${e.includeSettingsButton?p`
          <button
            class="link tooltip-link"
            role="link"
            jslog=${f.link("open-ai-settings").track({click:!0})}
            @click=${this.#N}
            aria-label=${L(m.learnMoreAriaLabel)}
          >${d(c.learnMore)}</button>
        `:b.nothing}
      </div>
    </devtools-tooltip>`}#I(){return p`
      <span
        class="ai-label-loading">
        <devtools-spinner></devtools-spinner>
        <span class="generate-label-text">${d(c.generatingLabel)}</span>
      </span>
    `}#C(){return this.#u==="generation_failed"?p`
        <span
          class="ai-label-error">
          <devtools-icon
            class="warning extra-large"
            name="warning"
            style="color: var(--ref-palette-error50)">
          </devtools-icon>
          <span class="generate-label-text">${d(c.generationFailed)}</span>
        </span>
      `:p`
      <!-- 'preventDefault' on the AI label button to prevent the label removal on blur  -->
      <span
        class="ai-label-button-wrapper only-pen-wrapper"
        @mousedown=${e=>e.preventDefault()}>
        <button
          class="ai-label-button enabled"
          @click=${this.#w}
          jslog=${f.link("timeline.annotations.ai-generate-label").track({click:!0})}>
          <devtools-icon
            class="pen-icon extra-large"
            name="pen-spark"
            style="color: var(--icon-primary);">
          </devtools-icon>
          <span class="generate-label-text">${L(m.generateLabelButton)}</span>
        </button>
        <devtools-button
          aria-details="info-tooltip"
          class="pen-icon"
          .title=${L(m.moreInfoAriaLabel)}
          .iconName=${"info"}
          .variant=${te.Button.Variant.ICON}
          ></devtools-button>
        ${this.#R({textContent:this.#h?d(c.generateLabelSecurityDisclaimerLoggingOff):d(c.generateLabelSecurityDisclaimer),includeSettingsButton:!0})}
      </span>
    `}#N(){this.#b?.value?.hidePopover(),O.ViewManager.ViewManager.instance().showView("chrome-ai")}#$(){let e=navigator.onLine===!1;return p`
      <!-- 'preventDefault' on the AI label button to prevent the label removal on blur  -->
      <span
        class="ai-label-disabled-button-wrapper only-pen-wrapper"
        @mousedown=${t=>t.preventDefault()}>
        <button
          class="ai-label-button disabled"
          ?disabled=${!0}
          @click=${this.#w}>
          <devtools-icon
            aria-details="info-tooltip"
            class="pen-icon extra-large"
            name="pen-spark"
            style="color: var(--sys-color-state-disabled);">
          </devtools-icon>
        </button>
        ${this.#R({textContent:d(e?c.autoAnnotationNotAvailableOfflineDisclaimer:c.autoAnnotationNotAvailableDisclaimer),includeSettingsButton:!e})}
      </span>
    `}#D(e){let t=e.relatedTarget;t&&this.#i.contains(t)||this.setLabelEditabilityAndRemoveEmptyLabel(!1)}#g(){let e=b.Directives.classMap({"input-field":!0,"fake-focus-state":this.#p});b.render(p`
        <style>${j}</style>
        <span class="label-parts-wrapper" role="region" aria-label=${L(m.entryLabel)}
          @focusout=${this.#D}
        >
          <span
            class="label-button-input-wrapper">
            <span
              class=${e}
              role="textbox"
              @focus=${()=>{this.setLabelEditabilityAndRemoveEmptyLabel(!0)}}
              @dblclick=${()=>{this.setLabelEditabilityAndRemoveEmptyLabel(!0)}}
              @keydown=${this.#x}
              @paste=${this.#S}
              @input=${this.#v}
              contenteditable=${this.#t?"plaintext-only":!1}
              jslog=${f.textField("timeline.annotations.entry-label-input").track({keydown:!0,click:!0,change:!0})}
              tabindex="0"
            ></span>
            ${this.#t&&this.#e?.innerText!==""?p`
              <button
                class="delete-button"
                @click=${()=>this.dispatchEvent(new E)}
                jslog=${f.action("timeline.annotations.delete-entry-label").track({click:!0})}>
              <devtools-icon name="cross" class="small" style="color: var(--color-background);"
              ></devtools-icon>
              </button>
            `:b.nothing}
            ${(()=>{switch(this.#u){case"hidden":return b.nothing;case"enabled":return this.#C();case"generating_label":return this.#I();case"generation_failed":return this.#C();case"disabled":return this.#$()}})()}
          </span>
          <svg class="connectorContainer">
            <line/>
            <circle/>
          </svg>
          <div class="entry-highlight-wrapper"></div>
        </span>`,this.#i,{host:this})}};customElements.define("devtools-entry-label-overlay",D);var he={};R(he,{DEFAULT_VIEW:()=>de,TimeRangeOverlay:()=>z});import*as S from"../../../../core/i18n/i18n.js";import*as _ from"../../../../core/platform/platform.js";import*as ae from"../../../../ui/legacy/legacy.js";import{Directives as M,html as Ce,render as Ie}from"../../../../ui/lit/lit.js";import*as le from"../../../../ui/visual_logging/visual_logging.js";var re=`@scope to (devtools-widget > *){:scope{display:flex;overflow:hidden;flex-direction:column;justify-content:flex-end;width:100%;height:100%;box-sizing:border-box;padding-bottom:5px;background:linear-gradient(180deg,rgb(255 125 210/0%) 0%,rgb(255 125 210/15%) 85%);border-color:var(--ref-palette-pink55);border-width:0 var(--sys-size-1) 5px;border-style:solid;pointer-events:none}.range-container{display:flex;align-items:center;flex-direction:column;text-align:center;box-sizing:border-box;pointer-events:all;user-select:none;color:var(--sys-color-pink);&.labelHidden{user-select:none;pointer-events:none;visibility:hidden}&.offScreenLeft{align-items:flex-start;text-align:left}&.offScreenRight{align-items:flex-end;text-align:right}}.label-text{width:100%;max-width:70px;min-width:fit-content;text-overflow:ellipsis;overflow:hidden;word-break:normal;overflow-wrap:anywhere;margin-bottom:3px;display:-webkit-box;white-space:break-spaces;background:var(--sys-color-cdt-base-container);line-clamp:2;-webkit-line-clamp:2;-webkit-box-orient:vertical}.duration{background:var(--sys-color-cdt-base-container)}.label-text[contenteditable='true']{outline:none;box-shadow:0 0 0 var(--sys-size-1) var(--ref-palette-pink55)}.label-text[contenteditable='false']{width:auto}}
/*# sourceURL=${import.meta.resolve("./timeRangeOverlay.css")} */`;var ce={timeRange:"Time range"},Ne=S.i18n.registerUIStrings("panels/timeline/overlays/components/TimeRangeOverlay.ts",ce),$e=S.i18n.getLocalizedString.bind(void 0,Ne);function De(i,e){let{x:t,width:n}=i,o=t+n,r=e.x,a=e.x+e.width,l=Math.max(r,t);return Math.min(a,o)-l}function He(i,e,t,n){let{canvasRect:o,hideLabelIfTooNarrow:r}=n,a=9;e.style.margin="0px";let l=i.getBoundingClientRect(),s=e.getBoundingClientRect(),u=De(l,o)-a,w=t.getBoundingClientRect().width;if(!w)return!1;let x=r&&u<=w;if(e.classList.toggle("labelHidden",x),x)return!0;let g=(l.width-s.width)/2,y=l.x+g<o.x,k=o.x+o.width,v=l.x+g+s.width>k;return e.classList.toggle("offScreenLeft",y&&!v),e.classList.toggle("offScreenRight",v&&!y),y&&(e.style.marginLeft=`${Math.abs(o.x-l.x)+a}px`),v&&(e.style.marginRight=`${l.right-o.right+a}px`),!0}var de=(i,e,t)=>{let n=s=>{(s.key===_.KeyboardUtilities.ENTER_KEY||s.key===_.KeyboardUtilities.ESCAPE_KEY)&&(s.stopPropagation(),i.onLabelEditComplete(),s.target instanceof HTMLElement&&s.target.blur())},o,r;Ie(Ce`
        <style>${re}</style>
        <span
          class="range-container"
          role="region"
          aria-label=${$e(ce.timeRange)}
          ${M.ref(s=>{o=s instanceof HTMLElement?s:void 0})}
        >
          <span
           class="label-text"
           role="textbox"
           @focusout=${i.onLabelFocusOut}
           @dblclick=${i.onLabelDblClick}
           @keydown=${n}
           @input=${s=>i.onLabelInput(s.target instanceof HTMLElement?s.target.textContent??"":"")}
           contenteditable=${i.isLabelEditable?"plaintext-only":!1}
           aria-label=${i.label}
           .textContent=${M.live(i.label)}
           jslog=${le.textField("timeline.annotations.time-range-label-input").track({keydown:!0,click:!0})}
           ${M.ref(s=>{s instanceof HTMLElement&&(e.focusLabel=()=>s.focus())})}
          ></span>
          <span
            class="duration"
            ${M.ref(s=>{r=s instanceof HTMLElement?s:void 0})}
          >${i.durationText}</span>
        </span>
      `,t);let a=o,l=r;a&&l?e.positionLabel=s=>He(t,a,l,s):e.positionLabel=()=>!1},z=class extends ae.Widget.Widget{#i=null;#n=null;#t="";#s=!0;#o=!1;onLabelChange=()=>{};onRemove=()=>{};#d;#e={focusLabel:()=>{},positionLabel:()=>!1};constructor(e,t=de){super(e),this.#d=t,this.requestUpdate()}set label(e){e!==this.#t&&(this.#t=e,this.#s=e==="",this.requestUpdate())}set canvasRect(e){e!==null&&(this.#n&&this.#n.x===e.x&&this.#n.width===e.width||(this.#n=e,this.requestUpdate()))}set duration(e){e!==this.#i&&(this.#i=e,this.requestUpdate())}updateLabelPositioning(){!this.#n||!this.#e.positionLabel({canvasRect:this.#n,hideLabelIfTooNarrow:!this.#s&&this.#t.length>0})||this.#t===""&&this.#r(!0)}#r(e){if(this.#t===""){this.#e.focusLabel();return}this.#s=e,this.#o=e,this.requestUpdate()}#a(e){e!==this.#t&&(this.#t=e,this.onLabelChange(this.#t),this.requestUpdate())}#l(){this.#t===""&&this.onRemove()}performUpdate(){this.#d({label:this.#t,durationText:this.#i?S.TimeUtilities.formatMicroSecondsTime(this.#i):"",isLabelEditable:this.#s,onLabelFocusOut:()=>this.#r(!1),onLabelDblClick:()=>this.#r(!0),onLabelEditComplete:this.#l.bind(this),onLabelInput:this.#a.bind(this)},this.#e,this.contentElement),this.updateLabelPositioning(),this.#o&&(this.#o=!1,this.#s&&this.#e.focusLabel())}};var ge={};R(ge,{DEFAULT_VIEW:()=>fe,TimespanBreakdownOverlay:()=>F});import*as be from"../../../../core/i18n/i18n.js";import*as pe from"../../../../ui/legacy/legacy.js";import{Directives as me,html as U,nothing as Oe,render as Me}from"../../../../ui/lit/lit.js";var ue=`@scope to (devtools-widget > *){.timespan-breakdown-overlay-section{pointer-events:auto;border:solid;border-color:var(--sys-color-on-surface);border-width:var(--sys-size-3) var(--sys-size-1) 0;align-content:flex-start;text-align:center;overflow:hidden;text-overflow:ellipsis;background-image:linear-gradient(180deg,var(--sys-color-on-primary),transparent);height:90%;box-sizing:border-box;padding-top:var(--sys-size-2);.is-below &{border-top-width:0;border-bottom-width:var(--sys-size-3);align-content:flex-end;padding-bottom:var(--sys-size-2);padding-top:0;.timespan-breakdown-overlay-label{display:flex;flex-direction:column-reverse}}}.timeline-segment-container{display:flex;overflow:hidden;flex-direction:row;justify-content:flex-end;align-items:flex-end;width:100%;box-sizing:border-box;height:100%;max-height:100px;.timespan-breakdown-overlay-section:first-child{border-left-width:var(--sys-size-1)!important}.timespan-breakdown-overlay-section:last-child{border-right-width:var(--sys-size-1)!important}}.timeline-segment-container.is-below{align-items:flex-start}.timeline-segment-container.even-number-of-sections{.timespan-breakdown-overlay-section:nth-child(even){height:100%}.timespan-breakdown-overlay-section:nth-child(odd){border-left-width:0;border-right-width:0}}.timeline-segment-container.odd-number-of-sections{.timespan-breakdown-overlay-section:nth-child(odd){height:100%}.timespan-breakdown-overlay-section:nth-child(even){border-left-width:0;border-right-width:0}}.timespan-breakdown-overlay-label{font-family:var(--default-font-family);font-size:var(--sys-typescale-body2-size);line-height:var(--sys-typescale-body4-line-height);font-weight:var(--ref-typeface-weight-medium);color:var(--sys-color-on-surface);text-align:center;box-sizing:border-box;width:max-content;padding:0 3px;overflow:hidden;text-overflow:ellipsis;text-wrap:nowrap;.duration-text{font-size:var(--sys-typescale-body4-size);text-overflow:ellipsis;overflow:hidden;text-wrap:nowrap;display:block}.discovery-time-ms{font-weight:var(--ref-typeface-weight-bold)}&.labelHidden{user-select:none;pointer-events:none;visibility:hidden}&.labelTruncated{max-width:100%}&.offScreenLeft{text-align:left}&.offScreenRight{text-align:right}}}
/*# sourceURL=${import.meta.resolve("./timespanBreakdownOverlay.css")} */`;var Be=(i,e)=>{let t=me.styleMap({left:e?`${e.left}px`:void 0,width:e?`${e.width}px`:void 0}),n=i.showDuration?be.TimeUtilities.formatMicroSecondsAsMillisFixed(i.bounds.range):"",o=i.label instanceof HTMLElement?i.label.textContent||"":typeof i.label=="string"?i.label:"",r=n?`${n} ${o}`:o;return U`
      <div class="timespan-breakdown-overlay-section" style=${t} title=${r}>
        <div class="timespan-breakdown-overlay-label">
          ${i.showDuration?U`<span class="duration-text">${n}</span> `:Oe}
          <span class="section-label-text">${i.label}</span>
        </div>
      </div>`},fe=(i,e,t)=>{let n=me.styleMap({left:i.left!==null?`${i.left}px`:void 0,width:i.width!==null?`${i.width}px`:void 0,top:i.top!==null?`${i.top}px`:void 0,maxHeight:i.maxHeight!==null?`${i.maxHeight}px`:void 0,position:"relative"});Me(U`
        <style>${ue}</style>
        <div style=${n} class=${i.className}>
          ${i.sections?.map((o,r)=>Be(o,i.positions[r]))}
        </div>`,t,{container:{classes:["devtools-timespan-breakdown-overlay"]}})},F=class extends pe.Widget.Widget{#i=null;#n=null;#t=[];#s=null;#o=null;#d=null;#e=null;#r;constructor(e,t=fe){super(e),this.#r=t,this.requestUpdate()}set top(e){this.#e=e,this.requestUpdate()}set maxHeight(e){this.#d=e,this.requestUpdate()}set width(e){this.#o=e,this.requestUpdate()}set left(e){this.#s=e,this.requestUpdate()}set isBelowEntry(e){this.element.classList.toggle("is-below",e)}set canvasRect(e){this.#i&&e&&this.#i.width===e.width&&this.#i.height===e.height||(this.#i=e,this.requestUpdate())}set widths(e){e!==this.#t&&(this.#t=e,this.requestUpdate())}set sections(e){e!==this.#n&&(this.#n=e,this.requestUpdate())}checkSectionLabelPositioning(){let e=this.element.querySelectorAll(".timespan-breakdown-overlay-section");if(!e||!this.#i)return;let t=9;for(let r of e){let a=r.querySelector(".timespan-breakdown-overlay-label");a&&(a.classList.remove("labelHidden","labelTruncated","offScreenLeft","offScreenRight"),a.style.marginLeft="")}let n=new Map;for(let r of e){let a=r.querySelector(".timespan-breakdown-overlay-label");if(!a)continue;let l=r.getBoundingClientRect(),s=a.getBoundingClientRect();n.set(r,{sectionRect:l,labelRect:s,label:a})}let o=30;for(let r of e){let a=n.get(r);if(!a)break;let{labelRect:l,sectionRect:s,label:u}=a,w=s.width<o,x=s.width-5<=l.width;if(u.classList.toggle("labelHidden",w),u.classList.toggle("labelTruncated",x),w||x)continue;let g=(s.width-l.width)/2,y=s.x+g<this.#i.x;u.classList.toggle("offScreenLeft",y);let k=this.#i.x+this.#i.width,v=s.x+g+l.width>k;if(u.classList.toggle("offScreenRight",v),y)u.style.marginLeft=`${Math.abs(this.#i.x-s.x)+t}px`;else if(v){let Le=k-l.width-s.x;u.style.marginLeft=`${Le}px`}else u.style.marginLeft=`${g}px`}}performUpdate(){let e="timeline-segment-container";this.#n&&(this.#n.length%2===0?e+=" even-number-of-sections":e+=" odd-number-of-sections"),this.#r({sections:this.#n,positions:this.#t,left:this.#s,width:this.#o,top:this.#e,maxHeight:this.#d,className:e},void 0,this.contentElement),this.checkSectionLabelPositioning()}};export{Y as EntriesLinkOverlay,oe as EntryLabelOverlay,he as TimeRangeOverlay,ge as TimespanBreakdownOverlay};
//# sourceMappingURL=components.js.map
