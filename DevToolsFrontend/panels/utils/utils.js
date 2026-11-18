import"../../ui/kit/kit.js";import"../../ui/components/icon_button/icon_button.js";import*as r from"../../core/common/common.js";import*as v from"../../core/i18n/i18n.js";import*as M from"../../core/sdk/sdk.js";import*as H from"../../models/formatter/formatter.js";import*as C from"../../models/persistence/persistence.js";import*as T from"../../ui/components/diff_view/diff_view.js";import{Directives as V,html as p}from"../../ui/lit/lit.js";import*as O from"../common/common.js";import*as P from"../snippets/snippets.js";var{ref:U,styleMap:j,ifDefined:x}=V,f={requestContentHeadersOverridden:"Both request content and headers are overridden",requestContentOverridden:"Request content is overridden",requestHeadersOverridden:"Request headers are overridden",thirdPartyPhaseout:"Cookies for this request are blocked either because of Chrome flags or browser configuration. Learn more in the Issues panel.",resourceTypeWithThrottling:"{PH1} (throttled to {PH2})",requestFailed:"{PH1} request failed",prefetchFailed:"{PH1} prefetch request failed"},q=v.i18n.registerUIStrings("panels/utils/utils.ts",f),u=v.i18n.getLocalizedString.bind(void 0,q),N=class S{static isFailedNetworkRequest(e){if(!e)return!1;if(e.failed&&!e.statusCode||e.statusCode>=400)return!0;let t=e.signedExchangeInfo();return!!(t!==null&&t.errors||e.corsErrorStatus())}static getIconForNetworkRequest(e){let t=e.resourceType();if(S.isFailedNetworkRequest(e)){let s,l;return e.resourceType()===r.ResourceType.resourceTypes.Prefetch||e.isPreloadRequest()?(s="warning-filled",e.resourceType()===r.ResourceType.resourceTypes.Prefetch?l=u(f.prefetchFailed,{PH1:t.title()}):l=u(f.requestFailed,{PH1:t.title()})):(l=u(f.requestFailed,{PH1:t.title()}),s="cross-circle-filled"),p`<devtools-icon
          class="icon"
          name=${s}
          title=${l}
          role=img
        ></devtools-icon>`}if(e.hasThirdPartyCookiePhaseoutIssue())return p`<devtools-icon
        class="icon"
        name="warning-filled"
        role=img
        title=${u(f.thirdPartyPhaseout)}
      ></devtools-icon>`;let c=e.hasOverriddenHeaders(),o=e.hasOverriddenContent,i;(c||o)&&(c&&o?i=u(f.requestContentHeadersOverridden):o?i=u(f.requestContentOverridden):i=u(f.requestHeadersOverridden));let n=r.ResourceType.ResourceType.fromMimeType(e.mimeType);n!==t&&n!==r.ResourceType.resourceTypes.Other&&(t===r.ResourceType.resourceTypes.Fetch||n===r.ResourceType.resourceTypes.Image||t===r.ResourceType.resourceTypes.Other&&n===r.ResourceType.resourceTypes.Script)&&(t=n);let a;if(t===r.ResourceType.resourceTypes.Image)a=p`<div class="image icon">
        <img
          class="image-network-icon-preview"
          title=${m(e)}
          alt=${m(e)}
          ${U(s=>{s&&e.populateImageSource(s)})}
        />
      </div>`;else if(t!==r.ResourceType.resourceTypes.Manifest&&r.ResourceType.ResourceType.simplifyContentType(e.mimeType)==="application/json")a=p`<devtools-icon
          class="icon" name="file-json" title=${m(e)} role=img
          style="color:var(--icon-file-script)">
        </devtools-icon>`;else{let{iconName:s,color:l}=S.iconDataForResourceType(t);a=p`<devtools-icon
          class="icon" name=${s} title=${m(e)}
          style=${j({color:l})}>
        </devtools-icon>`}if(i)return p`<div class="network-override-marker">${a}</div>`;return a;function m(s){if(i)return i;let l=M.NetworkManager.MultitargetNetworkManager.instance().appliedRequestConditions(s);if(!l?.urlPattern)return s.resourceType().title();let d=typeof l?.conditions.title=="string"?l?.conditions.title:l?.conditions.title();return u(f.resourceTypeWithThrottling,{PH1:s.resourceType().title(),PH2:d})}}static iconDataForResourceType(e){return e.isDocument()?{iconName:"file-document"}:e.isImage()?{iconName:"file-image",color:"var(--icon-file-image)"}:e.isFont()?{iconName:"file-font"}:e.isScript()?{iconName:"file-script"}:e.isStyleSheet()?{iconName:"file-stylesheet"}:e.name()===r.ResourceType.resourceTypes.Manifest.name()?{iconName:"file-manifest"}:e.name()===r.ResourceType.resourceTypes.Wasm.name()?{iconName:"file-wasm"}:e.name()===r.ResourceType.resourceTypes.WebSocket.name()||e.name()===r.ResourceType.resourceTypes.DirectSocket.name()?{iconName:"file-websocket"}:e.name()===r.ResourceType.resourceTypes.Media.name()?{iconName:"file-media"}:e.name()===r.ResourceType.resourceTypes.Fetch.name()||e.name()===r.ResourceType.resourceTypes.XHR.name()?{iconName:"file-fetch-xhr"}:{iconName:"file-generic"}}static getIconForSourceFile(e){let t=C.Persistence.PersistenceImpl.instance().binding(e),c=C.NetworkPersistenceManager.NetworkPersistenceManager.instance(),o="document",i=!1,n=!1;t?(P.ScriptSnippetFileSystem.isSnippetsUISourceCode(t.fileSystem)&&(o="snippet"),i=!0,n=c.project()===t.fileSystem.project()):c.isActiveHeaderOverrides(e)?(i=!0,n=!0):P.ScriptSnippetFileSystem.isSnippetsUISourceCode(e)&&(o="snippet");let a=t?O.PersistenceUtils.PersistenceUtils.tooltipForUISourceCode(e):void 0;return p`<devtools-file-source-icon
        class="icon"
        name=${o} 
        title=${x(a)} 
        .data=${{contentType:e.contentType().name(),hasDotBadge:i,isDotPurple:n,iconType:o}}></devtools-file-source-icon>`}static async formatCSSChangesFromDiff(e){let{originalLines:c,currentLines:o,rows:i}=T.DiffView.buildDiffRows(e),n=await b(c.join(`
`)),a=await b(o.join(`
`)),m="",s,l,d=!1;for(let{currentLineNumber:$,originalLineNumber:L,type:w}of i){if(w!==T.DiffView.RowType.DELETION&&w!==T.DiffView.RowType.ADDITION)continue;let y=w===T.DiffView.RowType.DELETION,E=y?c:o,g=y?L-1:$-1,k=E[g].trim(),{declarationIDToStyleRule:F,styleRuleIDToStyleRule:I}=y?n:a,R,h="";if(F.has(g)){R=F.get(g);let D=R.selector;D!==s&&D!==l&&(h+=`${D} {
`),h+="  ",d=!0}else d&&(h=`}

`,d=!1),I.has(g)&&(R=I.get(g));let W=y?`/* ${k} */`:k;m+=h+W+`
`,y?s=R?.selector:l=R?.selector}return m.length>0&&(m+="}"),m}static highlightElement(e){e.scrollIntoViewIfNeeded(),e.animate([{offset:0,backgroundColor:"rgba(255, 255, 0, 0.2)"},{offset:.1,backgroundColor:"rgba(255, 255, 0, 0.7)"},{offset:1,backgroundColor:"transparent"}],{duration:2e3,easing:"cubic-bezier(0, 0, 0.2, 1)"})}};async function b(S){let e=await new Promise(o=>{let i=[];H.FormatterWorkerPool.formatterWorkerPool().parseCSS(S,(n,a)=>{i.push(...a),n&&o(i)})}),t=new Map,c=new Map;for(let o of e)if("styleRange"in o){let i=o.selectorText.split(`
`).pop()?.trim();if(!i)continue;let n={rule:o,selector:i};c.set(o.styleRange.startLine,n);for(let a of o.properties)t.set(a.range.startLine,n)}return{declarationIDToStyleRule:t,styleRuleIDToStyleRule:c}}export{N as PanelUtils};
//# sourceMappingURL=utils.js.map
