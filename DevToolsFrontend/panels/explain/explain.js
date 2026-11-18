import"../../ui/components/spinners/spinners.js";import"../../ui/kit/kit.js";import*as w from"../../core/common/common.js";import*as i from"../../core/host/host.js";import*as $ from"../../core/i18n/i18n.js";import*as b from"../../core/root/root.js";import*as k from"../../models/ai_assistance/ai_assistance.js";import*as U from"../../third_party/marked/marked.js";import*as p from"../../ui/components/buttons/buttons.js";import*as D from"../../ui/components/input/input.js";import*as z from"../../ui/components/markdown_view/markdown_view.js";import*as A from"../../ui/legacy/legacy.js";import*as h from"../../ui/lit/lit.js";import*as v from"../../ui/visual_logging/visual_logging.js";import*as S from"../console/console.js";var N=`@scope to (devtools-widget > *){*{padding:0;margin:0;box-sizing:border-box}:scope{font-family:var(--default-font-family);font-size:inherit;display:block}.wrapper{background-color:var(--sys-color-cdt-base-container);border-radius:var(--sys-shape-corner-medium);container-type:inline-size;display:grid;animation:expand var(--sys-motion-duration-medium2) var(--sys-motion-easing-emphasized) forwards}.wrapper.closing{animation:collapse var(--sys-motion-duration-medium2) var(--sys-motion-easing-emphasized) forwards}@keyframes expand{from{grid-template-rows:0fr}to{grid-template-rows:1fr}}@keyframes collapse{from{grid-template-rows:1fr}to{grid-template-rows:0fr;padding-top:0;padding-bottom:0}}.animation-wrapper{overflow:hidden;padding:var(--sys-size-6) var(--sys-size-8)}.wrapper.top{border-radius:var(--sys-shape-corner-medium) var(--sys-shape-corner-medium) var(--sys-shape-corner-extra-small) var(--sys-shape-corner-extra-small)}.wrapper.bottom{margin-top:5px;border-radius:var(--sys-shape-corner-extra-small) var(--sys-shape-corner-extra-small) var(--sys-shape-corner-medium) var(--sys-shape-corner-medium)}header{display:flex;flex-direction:row;gap:var(--sys-size-4);color:var(--sys-color-on-surface);font-size:var(--sys-typescale-body3-size);font-style:normal;font-weight:500;margin-bottom:var(--sys-size-6);align-items:center}header:focus-visible{outline:none}header > .filler{display:flex;flex-direction:row;gap:var(--sys-size-5);align-items:center;flex:1}.reminder-container{border-radius:var(--sys-size-5);background-color:var(--sys-color-surface4);padding:var(--sys-size-8);font-weight:var(--ref-typeface-weight-medium);h3{font:inherit}}.reminder-items{display:grid;grid-template-columns:var(--sys-size-8) auto;gap:var(--sys-size-5) var(--sys-size-6);margin-top:var(--sys-size-6);line-height:var(--sys-size-8);font-weight:var(--ref-typeface-weight-regular)}main{--override-markdown-view-message-color:var(--sys-color-on-surface);color:var(--sys-color-on-surface);font-size:var(--sys-typescale-body4-size);font-style:normal;font-weight:400;line-height:var(--sys-size-9);p{margin-block:1em}ul{list-style-type:none;list-style-position:inside;padding-inline-start:0.2em;li{display:list-item;list-style-type:disc;list-style-position:outside;margin-inline-start:1em}li::marker{font-size:var(--sys-typescale-body5-size);line-height:1}}label{display:inline-flex;flex-direction:row;gap:0.5em;input,
      span{vertical-align:middle}input[type="checkbox"]{margin-top:0.3em}}}.opt-in-teaser{display:flex;gap:var(--sys-size-5)}devtools-markdown-view{margin-bottom:var(--sys-size-6)}footer{display:flex;flex-direction:row;align-items:center;color:var(--sys-color-on-surface);font-style:normal;font-weight:400;line-height:normal;margin-top:var(--sys-size-7);gap:var(--sys-size-13)}@container (max-width: 600px){footer{gap:var(--sys-size-5)}}footer > .filler{flex:1}footer .rating{display:flex;flex-direction:row;gap:var(--sys-size-5)}textarea{height:84px;padding:10px;border-radius:var(--sys-shape-corner-small);border:var(--sys-size-1) solid var(--sys-color-neutral-outline);width:100%;font-family:var(--default-font-family);font-size:inherit}.buttons{display:flex;gap:5px}@media (width <= 500px){.buttons{flex-wrap:wrap}}main .buttons{margin-top:var(--sys-size-6)}.disclaimer{display:flex;gap:var(--sys-size-2);color:var(--sys-color-on-surface-subtle);font-size:var(--sys-typescale-body5-size);align-items:flex-start;flex-direction:column}.link{color:var(--sys-color-primary);text-decoration-line:underline;devtools-icon{color:var(--sys-color-primary);width:var(--sys-size-7);height:var(--sys-size-7)}}button.link{border:none;background:none;cursor:pointer;font:inherit}.loader{background:linear-gradient(130deg,transparent 0%,var(--sys-color-gradient-tertiary) 20%,var(--sys-color-gradient-primary) 40%,transparent 60%,var(--sys-color-gradient-tertiary) 80%,var(--sys-color-gradient-primary) 100%);background-position:0% 0%;background-size:250% 250%;animation:gradient 5s infinite linear}@keyframes gradient{0%{background-position:0 0}100%{background-position:100% 100%}}summary{font-size:var(--sys-typescale-body4-size);font-style:normal;font-weight:400;line-height:var(--sys-size-9)}details{overflow:hidden;margin-top:10px}::details-content{height:0;transition:height var(--sys-motion-duration-short4) var(--sys-motion-easing-emphasized),content-visibility var(--sys-motion-duration-short4) var(--sys-motion-easing-emphasized) allow-discrete}[open]::details-content{height:auto}details.references{transition:margin-bottom var(--sys-motion-duration-short4) var(--sys-motion-easing-emphasized)}details.references[open]{margin-bottom:var(--sys-size-1)}h2{display:block;font-size:var(--sys-size-7);margin:0;font-weight:var(--ref-typeface-weight-medium);line-height:var(--sys-size-9)}h2:focus-visible{outline:none}.info{width:var(--sys-size-9);height:var(--sys-size-9)}.badge{background:linear-gradient(135deg,var(--sys-color-gradient-primary),var(--sys-color-gradient-tertiary));border-radius:var(--sys-size-3);height:var(--sys-size-9);devtools-icon{margin:var(--sys-size-2)}}.header-icon-container{background:linear-gradient(135deg,var(--sys-color-gradient-primary),var(--sys-color-gradient-tertiary));border-radius:var(--sys-size-4);height:36px;width:36px;display:flex;align-items:center;justify-content:center}.close-button{align-self:flex-start}.sources-list{padding-left:var(--sys-size-6);margin-bottom:var(--sys-size-6);list-style:none;counter-reset:sources;display:grid;grid-template-columns:var(--sys-size-9) auto;list-style-position:inside}.sources-list li{display:contents}.sources-list li::before{counter-increment:sources;content:"[" counter(sources) "]";display:table-cell}.sources-list devtools-link.highlighted{animation:highlight-fadeout 2s}@keyframes highlight-fadeout{from{background-color:var(--sys-color-yellow-container)}to{background-color:transparent}}.references-list{padding-left:var(--sys-size-8)}.references-list li{padding-left:var(--sys-size-3)}details h3{font-size:10px;font-weight:var(--ref-typeface-weight-medium);text-transform:uppercase;color:var(--sys-color-on-surface-subtle);padding-left:var(--sys-size-6)}.error-message{font:var(--sys-typescale-body4-bold)}@scope (.insight-sources){:root{padding:0;margin:0;box-sizing:border-box;display:block}ul{color:var(--sys-color-primary);font-size:var(--sys-typescale-body4-size);font-style:normal;font-weight:400;line-height:18px;margin-top:var(--sys-size-5);padding-left:var(--sys-size-6)}li{list-style-type:none}ul .link{color:var(--sys-color-primary);display:inline-flex!important;align-items:center;gap:var(--sys-size-3);text-decoration-line:underline}devtools-icon{height:var(--sys-size-8);width:var(--sys-size-8);margin-right:var(--sys-size-1)}devtools-icon[name="open-externally"]{color:var(--icon-link)}.source-disclaimer{color:var(--sys-color-on-surface-subtle)}}}
/*# sourceURL=${import.meta.resolve("././components/consoleInsight.css")} */`;var l={consoleMessage:"Console message",stackTrace:"Stack trace",networkRequest:"Network request",relatedCode:"Related code",generating:"Generating explanation\u2026",insight:"Explanation",closeInsight:"Close explanation",inputData:"Data used to understand this message",goodResponse:"Good response",badResponse:"Bad response",report:"Report legal issue",error:"DevTools encountered an error",errorBody:"Something went wrong. Try again.",opensInNewTab:"(opens in a new tab)",learnMore:"Learn more",notLoggedIn:"This feature is only available when you sign in to Chrome with your Google account",signIn:"Sign in",offlineHeader:"DevTools can\u2019t reach the internet",offline:"Check your internet connection and try again",signInToUse:"Sign in to use this feature",search:"Use search instead",reloadRecommendation:"Reload the page to capture related network request data for this message to get a better insight",turnOnInSettings:"Turn on {PH1} to use AI assistance for understanding and addressing console warnings and errors",settingsLink:"`Console insights` in Settings",references:"Sources and related content",relatedContent:"Related content",timedOut:"Generating a response took too long. Please try again.",notAvailableInIncognitoMode:"AI assistance isn\u2019t available in Incognito mode or Guest mode"},_=$.i18n.registerUIStrings("panels/explain/components/ConsoleInsight.ts",l),c=$.i18n.getLocalizedString.bind(void 0,_),j=h.i18nTemplate.bind(void 0,_),{render:W,html:a,Directives:C}=h,{widget:q}=A.Widget,M=class n extends Event{static eventName="closeinsight";constructor(){super(n.eventName,{composed:!0,bubbles:!0})}};function O(n){switch(n){case S.PromptBuilder.SourceType.MESSAGE:return c(l.consoleMessage);case S.PromptBuilder.SourceType.STACKTRACE:return c(l.stackTrace);case S.PromptBuilder.SourceType.NETWORK_REQUEST:return c(l.networkRequest);case S.PromptBuilder.SourceType.RELATED_CODE:return c(l.relatedCode)}}var Y="https://policies.google.com/terms",Q="https://policies.google.com/privacy",K="https://support.google.com/legal/answer/13505487",V="https://goo.gle/devtools-console-messages-ai",J="https://accounts.google.com",X=(g=>(g.INSIGHT="insight",g.LOADING="loading",g.ERROR="error",g.SETTING_IS_NOT_TRUE="setting-is-not-true",g.CONSENT_REMINDER="consent-reminder",g.NOT_LOGGED_IN="not-logged-in",g.SYNC_IS_PAUSED="sync-is-paused",g.OFFLINE="offline",g))(X||{}),Z={name:"citation",level:"inline",start(n){return n.match(/\[\^/)?.index},tokenizer(n){let e=n.match(/^\[\^(\d+)\]/);return e?{type:"citation",raw:e[0],linkText:Number(e[1])}:!1},renderer:()=>""};function G(n){return!!n.factualityMetadata?.facts.length}var R=n=>n.stopPropagation();function ee(n){return a`<devtools-button
    @click=${n}
    class="search-button"
    .variant=${p.Button.Variant.OUTLINED}
    .jslogContext=${"search"}
  >
    ${c(l.search)}
  </devtools-button>`}function te(){return a`<devtools-link href=${V} class="link" jslogcontext="learn-more">
    ${c(l.learnMore)}
  </devtools-link>`}function ie(n,e,t,s){return n.length?a`
    <ol class="sources-list">
      ${n.map((r,d)=>a`
        <li>
          <devtools-link
            href=${r}
            class=${C.classMap({link:!0,highlighted:d===e})}
            jslogcontext="references.console-insights"
            ${C.ref(o=>{s.citationLinks[d]=o})}
            @animationend=${t}
          >
            ${r}
          </devtools-link>
        </li>
      `)}
    </ol>
  `:h.nothing}function ne(n,e){return n.length===0?h.nothing:a`
    ${e.length?a`<h3>${c(l.relatedContent)}</h3>`:h.nothing}
    <ul class="references-list">
      ${n.map(t=>a`
        <li>
          <devtools-link
            href=${t}
            class="link"
            jslogcontext="references.console-insights"
          >
            ${t}
          </devtools-link>
        </li>
      `)}
    </ul>
  `}function se(){return a`
    <div role="presentation" aria-label="Loading" class="loader" style="clip-path: url('#clipPath');">
      <svg width="100%" height="64">
        <clipPath id="clipPath">
          <rect x="0" y="0" width="100%" height="16" rx="8"></rect>
          <rect x="0" y="24" width="100%" height="16" rx="8"></rect>
          <rect x="0" y="48" width="100%" height="16" rx="8"></rect>
        </clipPath>
      </svg>
    </div>`}function oe(n,e){return a`
    <div class="insight-sources">
      <ul>
        ${C.repeat(n,t=>t.value,t=>a`<li><devtools-link class="link" title="${O(t.type)} ${c(l.opensInNewTab)}" href="data:text/plain;charset=utf-8,${encodeURIComponent(t.value)}" .jslogContext=${"source-"+t.type}>
            <devtools-icon name="open-externally"></devtools-icon>
            ${O(t.type)}
          </devtools-link></li>`)}
        ${e?a`<li class="source-disclaimer">
          <devtools-icon name="warning"></devtools-icon>
          ${c(l.reloadRecommendation)}</li>`:h.nothing}
      </ul>
    </div>`}function re(n,{renderer:e,disableAnimations:t,areReferenceDetailsOpen:s,highlightedCitationIndex:r,callbacks:d},o){return a`
        ${n.validMarkdown?a`<devtools-markdown-view
            .data=${{tokens:n.tokens,renderer:e,animationEnabled:!t}}>
          </devtools-markdown-view>`:n.explanation}
        ${n.timedOut?a`<p class="error-message">${c(l.timedOut)}</p>`:h.nothing}
        ${G(n.metadata)?a`
          <details
            class="references"
            ?open=${s}
            jslog=${v.expand("references").track({click:!0})}
            @toggle=${d.onToggleReferenceDetails}
            @transitionend=${d.onReferencesOpen}
          >
            <summary>${c(l.references)}</summary>
            ${ie(n.directCitationUrls,r,d.onCitationAnimationEnd,o)}
            ${ne(n.relatedUrls,n.directCitationUrls)}
          </details>
        `:h.nothing}
        <details jslog=${v.expand("sources").track({click:!0})}>
          <summary>${c(l.inputData)}</summary>
          ${oe(n.sources,n.isPageReloadRecommended)}
        </details>
        <div class="buttons">
          ${ee(d.onSearch)}
        </div>`}function H(n){return a`<div class="error">${n}</div>`}function ae(n){return a`
    <h3>Things to consider</h3>
    <div class="reminder-items">
      <div>
        <devtools-icon name="google" class="medium">
        </devtools-icon>
      </div>
      <div>The console message, associated stack trace, related source code, and the associated network headers are sent to Google to generate explanations. ${n?"The content you submit and that is generated by this feature will not be used to improve Google\u2019s AI models.":"This data may be seen by human reviewers to improve this feature. Avoid sharing sensitive or personal information."}
      </div>
      <div>
        <devtools-icon name="policy" class="medium">
        </devtools-icon>
      </div>
      <div>Use of this feature is subject to the <devtools-link
          href=${Y}
          class="link"
          jslogcontext="terms-of-service.console-insights">
        Google Terms of Service
        </devtools-link> and <devtools-link
          href=${Q}
          class="link"
          jslogcontext="privacy-policy.console-insights">
        Google Privacy Policy
        </devtools-link>
      </div>
      <div>
        <devtools-icon name="warning" class="medium">
        </devtools-icon>
      </div>
      <div>
        <devtools-link
          href=${K}
          class="link"
          jslogcontext="code-snippets-explainer.console-insights"
        >Use generated code snippets with caution</devtools-link>
      </div>
    </div>`}function le(n){let e=a`
    <button
      class="link" role="link"
      jslog=${v.action("open-ai-settings").track({click:!0})}
      @click=${n}
    >${c(l.settingsLink)}</button>`;return a`
    <div class="badge">
      <devtools-icon name="lightbulb-spark" class="medium">
      </devtools-icon>
    </div>
    <div>
      ${j(l.turnOnInSettings,{PH1:e})} ${te()}
    </div>`}function de(){return H(b.Runtime.hostConfig.isOffTheRecord?c(l.notAvailableInIncognitoMode):c(l.notLoggedIn))}function B(n,e){return a`<span>
    AI tools may generate inaccurate info that doesn't represent Google's views. ${n?"The content you submit and that is generated by this feature will not be used to improve Google\u2019s AI models.":"Data sent to Google may be seen by human reviewers to improve this feature."} <button class="link" role="link" @click=${e}
              jslog=${v.action("open-ai-settings").track({click:!0})}>
      Open settings
    </button> or <devtools-link href=${V}
        class="link" jslogcontext="learn-more">
      learn more
    </devtools-link>
  </span>`}function P(n,e){return a`
    <div class="disclaimer">
      ${B(n,e)}
    </div>`}function ce(n){return b.Runtime.hostConfig.isOffTheRecord?h.nothing:a`
    <div class="filler"></div>
    <div>
      <devtools-button
        @click=${n}
        .variant=${p.Button.Variant.PRIMARY}
        .jslogContext=${"update-settings"}
      >
        ${c(l.signIn)}
      </devtools-button>
    </div>`}function ge(n,e){return a`
    <div class="filler"></div>
    <div class="buttons">
      <devtools-button
        @click=${n}
        .variant=${p.Button.Variant.TONAL}
        .jslogContext=${"settings"}
        .title=${"Settings"}
      >
        Settings
      </devtools-button>
      <devtools-button
        class='continue-button'
        @click=${e}
        .variant=${p.Button.Variant.PRIMARY}
        .jslogContext=${"continue"}
        .title=${"continue"}
      >
        Continue
      </devtools-button>
    </div>`}function ue(n,e,t){return a`
  <div class="disclaimer">
    ${B(n,t.onDisclaimerSettingsLink)}
  </div>
  <div class="filler"></div>
  <div class="rating">
    <devtools-button
      data-rating="true"
      .iconName=${"thumb-up"}
      .toggledIconName=${"thumb-up"}
      .variant=${p.Button.Variant.ICON_TOGGLE}
      .size=${p.Button.Size.SMALL}
      .toggleOnClick=${!1}
      .toggleType=${p.Button.ToggleType.PRIMARY}
      .disabled=${e!==void 0}
      .toggled=${e===!0}
      .title=${c(l.goodResponse)}
      .jslogContext=${"thumbs-up"}
      @click=${()=>t.onRating(!0)}
    ></devtools-button>
    <devtools-button
      data-rating="false"
      .iconName=${"thumb-down"}
      .toggledIconName=${"thumb-down"}
      .variant=${p.Button.Variant.ICON_TOGGLE}
      .size=${p.Button.Size.SMALL}
      .toggleOnClick=${!1}
      .toggleType=${p.Button.ToggleType.PRIMARY}
      .disabled=${e!==void 0}
      .toggled=${e===!1}
      .title=${c(l.badResponse)}
      .jslogContext=${"thumbs-down"}
      @click=${()=>t.onRating(!1)}
    ></devtools-button>
    <devtools-button
      .iconName=${"report"}
      .variant=${p.Button.Variant.ICON}
      .size=${p.Button.Size.SMALL}
      .title=${c(l.report)}
      .jslogContext=${"report"}
      @click=${t.onReport}
    ></devtools-button>
  </div>`}function he(){return a`
    <div class="header-icon-container">
      <devtools-icon name="lightbulb-spark" class="large">
      </devtools-icon>
    </div>`}function T({headerText:n,showIcon:e=!1,showSpinner:t=!1,onClose:s},r){return a`
    <header>
      ${e?he():h.nothing}
      <div class="filler">
        <h2 tabindex="-1" ${C.ref(r)}>
          ${n}
        </h2>
        ${t?a`<devtools-spinner></devtools-spinner>`:h.nothing}
      </div>
      <div class="close-button">
        <devtools-button
          .iconName=${"cross"}
          .variant=${p.Button.Variant.ICON}
          .size=${p.Button.Size.SMALL}
          .title=${c(l.closeInsight)}
          jslog=${v.close().track({click:!0})}
          @click=${s}
        ></devtools-button>
      </div>
    </header>
  `}var pe=(n,e,t)=>{let{state:s,noLogging:r,callbacks:d}=n,{onClose:o,onDisclaimerSettingsLink:f}=d,g=`${v.section(s.type).track({resize:!0})}`,m=h.nothing,u=h.nothing,x={},I;switch(s.type){case"loading":m=T({headerText:c(l.generating),onClose:o},e.headerRef),u=se();break;case"insight":m=T({headerText:c(l.insight),onClose:o,showSpinner:!s.completed},e.headerRef),u=re(s,n,e),I=ue(r,n.selectedRating,d);break;case"error":m=T({headerText:c(l.error),onClose:o},e.headerRef),u=H(c(l.errorBody)),I=P(r,f);break;case"consent-reminder":m=T({headerText:"Understand console messages with AI",onClose:o,showIcon:!0},e.headerRef),x["reminder-container"]=!0,u=ae(r),I=ge(d.onReminderSettingsLink,d.onConsentReminderConfirmed);break;case"setting-is-not-true":x["opt-in-teaser"]=!0,u=le(d.onEnableInsightsInSettingsLink);break;case"not-logged-in":case"sync-is-paused":m=T({headerText:c(l.signInToUse),onClose:o},e.headerRef),u=de(),I=ce(d.onGoToSignIn);break;case"offline":m=T({headerText:c(l.offlineHeader),onClose:o},e.headerRef),u=H(c(l.offline)),I=P(r,f);break}W(a`
    <style>${N}</style>
    <style>${D.checkboxStyles}</style>
    <div
      class=${C.classMap({wrapper:!0,closing:n.closing})}
      jslog=${v.pane("console-insights").track({resize:!0})}
      @animationend=${d.onAnimationEnd}
      @keydown=${R}
      @keyup=${R}
      @keypress=${R}
      @click=${R}
    >
      <div class="animation-wrapper">
        ${m}
        <main jslog=${g} class=${C.classMap(x)}>
          ${u}
        </main>
        ${I?a`<footer jslog=${v.section("footer")}>
          ${I}
        </footer>`:h.nothing}
      </div>
    </div>
  `,t)},L=class n extends A.Widget.Widget{static async create(e,t){let s=i.AidaClient.HostConfigTracker.instance().aidaAvailability??await i.AidaClient.AidaClient.checkAccessPreconditions();return a`<devtools-widget class="devtools-console-insight" ${q(r=>new n(e,t,s,r))}>
    </devtools-widget>`}disableAnimations=!1;#v;#o;#d;#c;#e;#f=C.createRef();#y=[];#n=-1;#r=!1;#b=!1;#g=!1;#s;#t;#a;#u;#I;constructor(e,t,s,r,d=pe){super(r),this.#v=d,this.#o=e,this.#d=t,this.#a=s,this.#t=this.#w(),this.#c=new z.MarkdownView.MarkdownInsightRenderer(this.#h.bind(this)),this.#I=new U.Marked.Marked({extensions:[Z]}),this.#e=this.#p(),this.#u=this.#S.bind(this),this.requestUpdate()}#h(e){if(this.#e.type!=="insight")return;let t=this.#r;this.#r=!0,this.#n=e-1,this.requestUpdate(),t&&this.#k()}#k(){let e=this.#y[this.#n];e&&(e.scrollIntoView({behavior:"auto"}),e.focus())}#p(){switch(this.#a){case i.AidaClient.AidaAccessPreconditions.AVAILABLE:{let e=w.Settings.Settings.instance().createSetting("console-insights-skip-reminder",!1,w.Settings.SettingStorageType.SESSION).get();return{type:"loading",consentOnboardingCompleted:this.#m().get()||e}}case i.AidaClient.AidaAccessPreconditions.NO_ACCOUNT_EMAIL:return{type:"not-logged-in"};case i.AidaClient.AidaAccessPreconditions.SYNC_IS_PAUSED:return{type:"sync-is-paused"};case i.AidaClient.AidaAccessPreconditions.NO_INTERNET:return{type:"offline"}}}#w(){return new k.AiSetting.AiSetting(k.AiUtils.consoleInsightsEnabledSettingDescriptor,i.AidaClient.HostConfigTracker.instance(),w.Settings.Settings.instance())}#m(){return w.Settings.Settings.instance().createLocalSetting("console-insights-onboarding-finished",!1)}wasShown(){super.wasShown(),this.focus(),this.#t.addEventListener(k.AiSetting.Events.CHANGED,this.#C,this);let e=b.Runtime.hostConfig.aidaAvailability?.blockedByAge===!0;this.#e.type==="loading"&&this.#t?.getIfNotDisabled()===!0&&!e&&this.#e.consentOnboardingCompleted&&i.userMetrics.actionTaken(i.UserMetrics.Action.GeneratingInsightWithoutDisclaimer),i.AidaClient.HostConfigTracker.instance().addEventListener(i.AidaClient.Events.AIDA_AVAILABILITY_CHANGED,this.#u);let t=i.AidaClient.HostConfigTracker.instance().aidaAvailability;t!==void 0&&this.#A(t),this.#e.type!=="insight"&&this.#e.type!=="error"&&(this.#e=this.#p()),this.#l()}willHide(){super.willHide(),this.#t.removeEventListener(k.AiSetting.Events.CHANGED,this.#C,this),i.AidaClient.HostConfigTracker.instance().removeEventListener(i.AidaClient.Events.AIDA_AVAILABILITY_CHANGED,this.#u)}#A(e){e!==this.#a&&(this.#a=e,this.#e=this.#p(),this.#l())}#S(e){this.#A(e.data)}#C(){this.#t?.getIfNotDisabled()===!0&&this.#m().set(!0),this.#e.type==="setting-is-not-true"&&this.#t?.getIfNotDisabled()===!0&&(this.#i({type:"loading",consentOnboardingCompleted:!0}),i.userMetrics.actionTaken(i.UserMetrics.Action.InsightsOptInTeaserConfirmedInSettings),this.#l()),this.#e.type==="consent-reminder"&&this.#t?.getIfNotDisabled()===!1&&(this.#i({type:"loading",consentOnboardingCompleted:!1}),i.userMetrics.actionTaken(i.UserMetrics.Action.InsightsReminderTeaserAbortedInSettings),this.#l())}#i(e){this.#b=this.#e.type!==e.type,this.#e=e,this.requestUpdate()}async#l(){if(this.#e.type!=="loading")return;let e=b.Runtime.hostConfig.aidaAvailability?.blockedByAge===!0;if(this.#t?.getIfNotDisabled()!==!0||e){this.#i({type:"setting-is-not-true"}),i.userMetrics.actionTaken(i.UserMetrics.Action.InsightsOptInTeaserShown);return}if(!this.#e.consentOnboardingCompleted){let{sources:t,isPageReloadRecommended:s}=await this.#o.buildPrompt();this.#i({type:"consent-reminder",sources:t,isPageReloadRecommended:s}),i.userMetrics.actionTaken(i.UserMetrics.Action.InsightsReminderTeaserShown);return}await this.#T()}#R(){this.#e.type==="consent-reminder"&&i.userMetrics.actionTaken(i.UserMetrics.Action.InsightsReminderTeaserCanceled),this.#g=!0,this.requestUpdate()}#L(){if(this.#g){this.contentElement.dispatchEvent(new M);return}this.#b&&this.#f.value?.focus()}#E(){this.#n!==-1&&(this.#n=-1,this.requestUpdate())}#x(e){if(this.#e.type!=="insight")throw new Error("Unexpected state");if(this.#e.metadata?.rpcGlobalId===void 0)throw new Error("RPC Id not in metadata");if(this.#s!==void 0)return;this.#s=e,this.requestUpdate(),this.#s?i.userMetrics.actionTaken(i.UserMetrics.Action.InsightRatedPositive):i.userMetrics.actionTaken(i.UserMetrics.Action.InsightRatedNegative);let t=b.Runtime.hostConfig.aidaAvailability?.disallowLogging??!0;return this.#d.registerClientEvent({corresponding_aida_rpc_global_id:this.#e.metadata.rpcGlobalId,disable_user_content_logging:t,do_conversation_client_event:{user_feedback:{sentiment:this.#s?i.AidaClient.Rating.POSITIVE:i.AidaClient.Rating.NEGATIVE}}})}#M(){i.InspectorFrontendHost.InspectorFrontendHostInstance.openInNewTab(k.AiUtils.REPORT_LEGAL_ISSUE_URL)}#H(){let e=this.#o.getSearchQuery();i.InspectorFrontendHost.InspectorFrontendHostInstance.openSearchResultsInNewTab(e)}async#$(){this.#m().set(!0),this.#i({type:"loading",consentOnboardingCompleted:!0}),i.userMetrics.actionTaken(i.UserMetrics.Action.InsightsReminderTeaserConfirmed),await this.#T()}#N(e,t){let s=[];if(!G(t)||!t.attributionMetadata)return{explanationWithCitations:e,directCitationUrls:s};let{attributionMetadata:r}=t,d=r.citations.filter(f=>f.sourceType===i.AidaClient.CitationSourceType.WORLD_FACTS).sort((f,g)=>(g.endIndex||0)-(f.endIndex||0)),o=e;for(let[f,g]of d.entries()){let m=/[.,:;!?]*\s/g;m.lastIndex=g.endIndex||0;let u=m.exec(o);u&&g.uri&&(o=o.slice(0,u.index)+`[^${d.length-f}]`+o.slice(u.index),s.push(g.uri))}return s.reverse(),{explanationWithCitations:o,directCitationUrls:s}}#O(e){for(let t of e)if(t.type==="code"){let s=t.text.match(/\[\^\d+\]/g);if(t.text=t.text.replace(/\[\^\d+\]/g,""),s?.length){let r=s.map(d=>{let o=parseInt(d.slice(2,-1),10);return{index:o,clickHandler:this.#h.bind(this,o)}});t.citations=r}}}#P(e,t){if(!t.factualityMetadata?.facts.length)return[];let s=t.factualityMetadata.facts.filter(o=>o.sourceUri&&!e.includes(o.sourceUri)).map(o=>o.sourceUri)||[],r=t.attributionMetadata?.citations.filter(o=>o.sourceType===i.AidaClient.CitationSourceType.TRAINING_DATA&&(o.uri||o.repository)).map(o=>o.uri||`https://www.github.com/${o.repository}`)||[],d=[...new Set(r.filter(o=>!s.includes(o)&&!e.includes(o)))];return s.push(...d),s}async#T(){try{for await(let{sources:e,isPageReloadRecommended:t,explanation:s,metadata:r,completed:d}of this.#D()){let{explanationWithCitations:o,directCitationUrls:f}=this.#N(s,r),g=this.#P(f,r),m=this.#U(o),u=m!==!1;u&&this.#O(m),this.#i({type:"insight",tokens:u?m:[],validMarkdown:u,explanation:s,sources:e,metadata:r,isPageReloadRecommended:t,completed:d,directCitationUrls:f,relatedUrls:g})}i.userMetrics.actionTaken(i.UserMetrics.Action.InsightGenerated)}catch(e){console.error("[ConsoleInsight] Error in #generateInsight:",e),i.userMetrics.actionTaken(i.UserMetrics.Action.InsightErrored),e.message==="doAidaConversation timed out"&&this.#e.type==="insight"?(this.#e.timedOut=!0,this.#i({...this.#e,completed:!0,timedOut:!0})):this.#i({type:"error",error:e.message})}}#U(e){try{let t=this.#I.lexer(e);for(let s of t)this.#c.renderToken(s);return t}catch{return i.userMetrics.actionTaken(i.UserMetrics.Action.InsightErroredMarkdown),!1}}async*#D(){let{prompt:e,sources:t,isPageReloadRecommended:s}=await this.#o.buildPrompt();try{for await(let r of this.#d.doConversation(i.AidaClient.AidaClient.buildConsoleInsightsRequest(e)))yield{sources:t,isPageReloadRecommended:s,...r}}catch(r){throw r.message==="Server responded: permission denied"?i.userMetrics.actionTaken(i.UserMetrics.Action.InsightErroredPermissionDenied):r.message.startsWith("Cannot send request:")?i.userMetrics.actionTaken(i.UserMetrics.Action.InsightErroredCannotSend):r.message.startsWith("Request failed:")?i.userMetrics.actionTaken(i.UserMetrics.Action.InsightErroredRequestFailed):r.message.startsWith("Cannot parse chunk:")?i.userMetrics.actionTaken(i.UserMetrics.Action.InsightErroredCannotParseChunk):r.message==="Unknown chunk result"?i.userMetrics.actionTaken(i.UserMetrics.Action.InsightErroredUnknownChunk):r.message.startsWith("Server responded:")?i.userMetrics.actionTaken(i.UserMetrics.Action.InsightErroredApi):i.userMetrics.actionTaken(i.UserMetrics.Action.InsightErroredOther),r}}#z(){i.InspectorFrontendHost.InspectorFrontendHostInstance.openInNewTab(J)}#_(e){let t=e.target;t&&(this.#r=t.open,t.open||(this.#n=-1),this.requestUpdate())}#V(){A.ViewManager.ViewManager.instance().showView("chrome-ai")}#G(){i.userMetrics.actionTaken(i.UserMetrics.Action.InsightsReminderTeaserSettingsLinkClicked),A.ViewManager.ViewManager.instance().showView("chrome-ai")}#B(){i.userMetrics.actionTaken(i.UserMetrics.Action.InsightsOptInTeaserSettingsLinkClicked),A.ViewManager.ViewManager.instance().showView("chrome-ai")}performUpdate(){let e={state:this.#e,closing:this.#g,disableAnimations:this.disableAnimations,renderer:this.#c,citationClickHandler:this.#h.bind(this),selectedRating:this.#s,noLogging:b.Runtime.hostConfig.aidaAvailability?.enterprisePolicyValue===b.Runtime.GenAiEnterprisePolicyValue.ALLOW_WITHOUT_LOGGING,areReferenceDetailsOpen:this.#r,highlightedCitationIndex:this.#n,callbacks:{onClose:this.#R.bind(this),onAnimationEnd:this.#L.bind(this),onCitationAnimationEnd:this.#E.bind(this),onSearch:this.#H.bind(this),onRating:this.#x.bind(this),onReport:this.#M.bind(this),onGoToSignIn:this.#z.bind(this),onConsentReminderConfirmed:this.#$.bind(this),onToggleReferenceDetails:this.#_.bind(this),onDisclaimerSettingsLink:this.#V.bind(this),onReminderSettingsLink:this.#G.bind(this),onEnableInsightsInSettingsLink:this.#B.bind(this),onReferencesOpen:this.#k.bind(this)}},t={headerRef:this.#f,citationLinks:[]};this.#v(e,t,this.contentElement),this.#y=t.citationLinks}};import*as y from"../../core/host/host.js";import*as E from"../console/console.js";var F=class{handleAction(e,t){switch(t){case"explain.console-message.context":case"explain.console-message.context.error":case"explain.console-message.context.warning":case"explain.console-message.context.other":case"explain.console-message.teaser":case"explain.console-message.hover":{let s=e.flavor(E.ConsoleViewMessage.ConsoleViewMessage);if(s){t.startsWith("explain.console-message.context")?y.userMetrics.actionTaken(y.UserMetrics.Action.InsightRequestedViaContextMenu):t==="explain.console-message.teaser"?y.userMetrics.actionTaken(y.UserMetrics.Action.InsightRequestedViaTeaser):t==="explain.console-message.hover"&&y.userMetrics.actionTaken(y.UserMetrics.Action.InsightRequestedViaHoverButton);let r=new E.PromptBuilder.PromptBuilder(s),d=new y.AidaClient.AidaClient;return L.create(r,d).then(o=>{s.setInsight(o)}),!0}return!1}}return!1}};export{F as ActionDelegate,M as CloseEvent,L as ConsoleInsight,pe as DEFAULT_VIEW,X as State};
//# sourceMappingURL=explain.js.map
