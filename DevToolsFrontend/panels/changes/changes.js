var Y=Object.defineProperty;var g=(s,e)=>{for(var i in e)Y(s,i,{get:e[i],enumerable:!0})};var G={};g(G,{ChangesView:()=>V,DEFAULT_VIEW:()=>B});import"../../ui/legacy/legacy.js";import*as T from"../../core/i18n/i18n.js";import*as h from"../../models/workspace_diff/workspace_diff.js";import*as n from"../../ui/legacy/legacy.js";import*as ce from"../../ui/lit/lit.js";import*as R from"../../ui/visual_logging/visual_logging.js";var q={};g(q,{ChangesSidebar:()=>c,DEFAULT_VIEW:()=>z,Events:()=>N});import"../../ui/kit/kit.js";import*as L from"../../core/common/common.js";import*as C from"../../core/i18n/i18n.js";import*as a from"../../models/workspace/workspace.js";import*as S from"../../models/workspace_diff/workspace_diff.js";import*as $ from"../../ui/legacy/legacy.js";import*as Z from"../../ui/lit/lit.js";import*as _ from"../../ui/visual_logging/visual_logging.js";import*as F from"../snippets/snippets.js";var x=`@scope to (devtools-widget > *){.tree-outline li{min-height:var(--sys-size-9)}devtools-icon{color:var(--icon-file-default);margin-right:var(--sys-size-4)}.tree-element-title > div{display:flex;align-items:center}.navigator-sm-script-tree-item devtools-icon,
.navigator-script-tree-item devtools-icon,
.navigator-snippet-tree-item devtools-icon{color:var(--icon-file-script)}.navigator-sm-stylesheet-tree-item devtools-icon,
.navigator-stylesheet-tree-item devtools-icon{color:var(--icon-file-styles)}.navigator-image-tree-item devtools-icon{color:var(--icon-file-image)}.navigator-font-tree-item devtools-icon{color:var(--icon-file-font)}.tree-outline li:hover:not(.selected) .selection{display:block;& devtools-icon{color:var(--icon-default-hover)}}@media (forced-colors: active){li,
  devtools-icon{forced-color-adjust:none;color:ButtonText!important}}}
/*# sourceURL=${import.meta.resolve("./changesSidebar.css")} */`;var M={sFromSourceMap:"{PH1} (from source map)"},ee=C.i18n.registerUIStrings("panels/changes/ChangesSidebar.ts",M),ie=C.i18n.getLocalizedString.bind(void 0,ee),{render:oe,html:U}=Z,z=(s,e,i)=>{let o=t=>t.contentType().isFromSourceMap()?ie(M.sFromSourceMap,{PH1:t.displayName()}):t.url(),r=t=>F.ScriptSnippetFileSystem.isSnippetsUISourceCode(t)?"snippet":"document";oe(U`<devtools-tree
             navigation-variant
             hide-overflow .template=${U`
               <ul role="tree">
                 ${s.sourceCodes.values().map(t=>U`
                   <li
                     role="treeitem"
                     @select=${()=>s.onSelect(t)}
                     ?selected=${t===s.selectedSourceCode}>
                       <style>${x}</style>
                       <div class=${"navigator-"+t.contentType().name()+"-tree-item"}>
                         <devtools-icon name=${r(t)}></devtools-icon>
                         <span title=${o(t)}>
                           <span ?hidden=${!t.isDirty()}>*</span>
                           ${t.displayName()}
                         </span>
                       </div>
                   </li>`)}
               </ul>`}></devtools-tree>`,i,{container:{attributes:{jslog:`${_.pane("sidebar").track({resize:!0})}`}}})},te=L.ObjectWrapper.eventMixin($.Widget.Widget),c=class extends te{#o=null;#e;#i=new Set;#t=null;constructor(e,i=z){super(e),this.#e=i}set workspaceDiff(e){this.#o&&(this.#o.modifiedUISourceCodes().forEach(this.#n.bind(this)),this.#o.removeEventListener(S.WorkspaceDiff.Events.MODIFIED_STATUS_CHANGED,this.uiSourceCodeModifiedStatusChanged,this)),this.#o=e,this.#o.modifiedUISourceCodes().forEach(this.#r.bind(this)),this.#o.addEventListener(S.WorkspaceDiff.Events.MODIFIED_STATUS_CHANGED,this.uiSourceCodeModifiedStatusChanged,this),this.requestUpdate()}selectedUISourceCode(){return this.#t}performUpdate(){let e={onSelect:i=>this.#s(i),sourceCodes:this.#i,selectedSourceCode:this.#t};this.#e(e,{},this.contentElement)}#s(e){this.#t=e,this.dispatchEventToListeners("SelectedUISourceCodeChanged"),this.requestUpdate()}#r(e){this.#i.add(e),e.addEventListener(a.UISourceCode.Events.TitleChanged,this.requestUpdate,this),e.addEventListener(a.UISourceCode.Events.WorkingCopyChanged,this.requestUpdate,this),e.addEventListener(a.UISourceCode.Events.WorkingCopyCommitted,this.requestUpdate,this),this.requestUpdate()}#n(e){if(e.removeEventListener(a.UISourceCode.Events.TitleChanged,this.requestUpdate,this),e.removeEventListener(a.UISourceCode.Events.WorkingCopyChanged,this.requestUpdate,this),e.removeEventListener(a.UISourceCode.Events.WorkingCopyCommitted,this.requestUpdate,this),e===this.#t){let i;for(let o of this.#i.values()){if(o===e)break;i=o}this.#i.delete(e),this.#s(i??this.#i.values().next().value??null)}else this.#i.delete(e);this.requestUpdate()}uiSourceCodeModifiedStatusChanged(e){let{isModified:i,uiSourceCode:o}=e.data;i?this.#r(o):this.#n(o),this.requestUpdate()}},N=(e=>(e.SELECTED_UI_SOURCE_CODE_CHANGED="SelectedUISourceCodeChanged",e))(N||{});var A=`[slot="main"]{flex-direction:column;display:flex}[slot="sidebar"]{overflow:auto}.diff-container{flex:1;overflow:auto;& .widget:first-child{height:100%}.combined-diff-view{padding-inline:var(--sys-size-6);padding-block:var(--sys-size-4)}}:focus.selected{background-color:var(--sys-color-tonal-container);color:var(--sys-color-on-tonal-container)}.changes-toolbar{background-color:var(--sys-color-cdt-base-container);border-top:var(--sys-size-1) solid var(--sys-color-divider)}[hidden]{display:none!important}
/*# sourceURL=${import.meta.resolve("./changesView.css")} */`;var E={};g(E,{CombinedDiffView:()=>l});import"../../ui/kit/kit.js";import*as O from"../../core/common/common.js";import*as k from"../../core/i18n/i18n.js";import*as m from"../../models/persistence/persistence.js";import*as y from"../../models/workspace_diff/workspace_diff.js";import*as w from"../../ui/components/buttons/buttons.js";import*as u from"../../ui/legacy/legacy.js";import*as f from"../../ui/lit/lit.js";import*as v from"../../ui/visual_logging/visual_logging.js";import*as P from"../utils/utils.js";var H=`.combined-diff-view{display:flex;flex-direction:column;gap:var(--sys-size-5);height:100%;background-color:var(--sys-color-surface3);overflow:auto;details{flex-shrink:0;border-radius:var(--sys-shape-corner-medium-small);&.selected{outline:var(--sys-size-2) solid var(--sys-color-divider-on-tonal-container)}summary{background-color:var(--sys-color-surface1);border-radius:var(--sys-shape-corner-medium-small);height:var(--sys-size-12);padding:var(--sys-size-3);font:var(--sys-typescale-body5-bold);display:flex;justify-content:space-between;gap:var(--sys-size-2);&:focus-visible{outline:var(--sys-size-2) solid var(--sys-color-state-focus-ring);outline-offset:calc(-1 * var(--sys-size-2))}.summary-left{display:flex;align-items:center;min-width:0;flex-grow:0;.file-name-link{margin-left:var(--sys-size-5);width:100%;text-overflow:ellipsis;overflow:hidden;text-wrap-mode:nowrap;border:none;background:none;font:inherit;padding:0;&:hover{color:var(--sys-color-primary);text-decoration:underline;cursor:pointer}&:focus-visible{outline:var(--sys-size-2) solid var(--sys-color-state-focus-ring);outline-offset:var(--sys-size-2)}}devtools-icon{transform:rotate(270deg)}devtools-file-source-icon{height:var(--sys-size-8);width:var(--sys-size-8);flex-shrink:0}}.summary-right{flex-shrink:0;display:flex;align-items:center;gap:var(--sys-size-2);padding-right:var(--sys-size-4);.copied{font:var(--sys-typescale-body5-regular)}}&::marker{content:''}}.diff-view-container{overflow-x:auto;background-color:var(--sys-color-cdt-base-container);border-bottom-left-radius:var(--sys-shape-corner-medium-small);border-bottom-right-radius:var(--sys-shape-corner-medium-small)}&[open]{summary{border-radius:0;border-top-left-radius:var(--sys-shape-corner-medium-small);border-top-right-radius:var(--sys-shape-corner-medium-small);devtools-icon{transform:rotate(0deg)}}}}}
/*# sourceURL=${import.meta.resolve("./combinedDiffView.css")} */`;var se=1e3,{html:D,Directives:{classMap:re}}=f,p={copied:"Copied to clipboard",copyFile:"Copy file {PH1} to clipboard"},ne=k.i18n.registerUIStrings("panels/changes/CombinedDiffView.ts",p),I=k.i18n.getLocalizedString.bind(void 0,ne);function ae(s){let{fileName:e,fileUrl:i,mimeType:o,icon:r,diff:t,copied:d,selectedFileUrl:X,onCopy:J,onFileNameClick:K}=s,Q=re({selected:X===i});return D`
    <details open class=${Q} jslog=${v.section("diff-view")}>
      <summary>
        <div class="summary-left">
          <devtools-icon class="drop-down-icon" name="arrow-drop-down"></devtools-icon>
          ${r}
          <button class="file-name-link" jslog=${v.action("jump-to-file")} @click=${()=>K(i)}>${e}</button>
        </div>
        <div class="summary-right">
          <devtools-button
            .title=${I(p.copyFile,{PH1:e})}
            .size=${w.Button.Size.SMALL}
            .iconName=${"copy"}
            .jslogContext=${"combined-diff-view.copy"}
            .variant=${w.Button.Variant.ICON}
            @click=${()=>J(i)}
          ></devtools-button>
          ${d?D`<span class="copied">${I(p.copied)}</span>`:f.nothing}
        </div>
      </summary>
      <div class="diff-view-container">
        <devtools-diff-view
          .data=${{diff:t,mimeType:o}}>
        </devtools-diff-view>
      </div>
    </details>
  `}var de=(s,e,i)=>{f.render(D`
      <div class="combined-diff-view">
        ${s.singleDiffViewInputs.map(o=>ae(o))}
      </div>
    `,i)},l=class extends u.Widget.Widget{ignoredUrls=[];#o;#e;#i=[];#t={};#s;#r={};constructor(e,i=de){super(e),this.registerRequiredCSS(H),this.#s=i}wasShown(){super.wasShown(),this.#e?.addEventListener(y.WorkspaceDiff.Events.MODIFIED_STATUS_CHANGED,this.#d,this),this.#a()}willHide(){super.willHide(),this.#e?.removeEventListener(y.WorkspaceDiff.Events.MODIFIED_STATUS_CHANGED,this.#d,this)}set workspaceDiff(e){this.#e=e,this.#a()}set selectedFileUrl(e){this.#o=e,this.requestUpdate(),this.updateComplete.then(()=>{this.#r.scrollToSelectedDiff?.()})}async#n(e){let i=this.#i.find(r=>r.url()===e);if(!i)return;let o=i.workingCopyContentData();o.isTextContent&&(u.UIUtils.copyTextToClipboard(o.text,I(p.copied)),this.#t[e]=!0,this.requestUpdate(),setTimeout(()=>{delete this.#t[e],this.requestUpdate()},se))}#c(e){let i=this.#i.find(o=>o.url()===e);O.Revealer.reveal(i)}async#a(){if(!this.#e)return;let e=this.#i,i=this.#e.modifiedUISourceCodes();e.filter(t=>!i.includes(t)).forEach(t=>this.#e?.unsubscribeFromDiffChange(t,this.requestUpdate,this)),i.filter(t=>!e.includes(t)).forEach(t=>this.#e?.subscribeToDiffChange(t,this.requestUpdate,this)),this.#i=i,this.isShowing()&&this.requestUpdate()}async#d(){this.#e&&await this.#a()}async performUpdate(){let i=(await Promise.all(this.#i.map(async o=>{for(let t of this.ignoredUrls)if(o.url().startsWith(t))return;return{diff:(await this.#e?.requestDiff(o))?.diff??[],uiSourceCode:o}}))).filter(o=>!!o).map(({uiSourceCode:o,diff:r})=>{let t=o.fullDisplayName(),d=m.Persistence.PersistenceImpl.instance().fileSystem(o);return d&&(t=[d.project().displayName(),...m.FileSystemWorkspaceBinding.FileSystemWorkspaceBinding.relativePath(d)].join("/")),{diff:r,fileName:`${o.isDirty()?"*":""}${t}`,fileUrl:o.url(),mimeType:o.mimeType(),icon:P.PanelUtils.getIconForSourceFile(o),copied:this.#t[o.url()],selectedFileUrl:this.#o,onCopy:this.#n.bind(this),onFileNameClick:this.#c.bind(this)}});this.#s({singleDiffViewInputs:i},this.#r,this.contentElement)}};var le="https://developer.chrome.com/docs/devtools/changes",b={noChanges:"No changes yet",changesViewDescription:"Track code changes made within DevTools"},fe=T.i18n.registerUIStrings("panels/changes/ChangesView.ts",b),j=T.i18n.getLocalizedString.bind(void 0,fe),{render:pe,html:me}=ce,{widget:W}=n.Widget,B=(s,e,i)=>{pe(me`
      <style>${A}</style>
      <devtools-split-view direction=column>
        <div class=vbox slot="main">
          <devtools-widget
            ?hidden=${s.workspaceDiff.modifiedUISourceCodes().length>0}
            ${W(n.EmptyWidget.EmptyWidget,{header:j(b.noChanges),text:j(b.changesViewDescription),link:le})}>
          </devtools-widget>
          <div class=diff-container role=tabpanel ?hidden=${s.workspaceDiff.modifiedUISourceCodes().length===0}>
            ${W(l,{selectedFileUrl:s.selectedSourceCode?.url(),workspaceDiff:s.workspaceDiff})}
          </div>
        </div>
        <devtools-widget slot="sidebar" ${W(c,{workspaceDiff:s.workspaceDiff})}
          @SelectedUISourceCodeChanged=${o=>{let r=n.Widget.Widget.get(o.target);s.onSelect(r.selectedUISourceCode())}}>
        </devtools-widget>
      </devtools-split-view>`,i,{container:{attributes:{jslog:`${R.panel("changes").track({resize:!0})}`}}})},V=class s extends n.Widget.VBox{#o;#e=null;#i;constructor(e,i=B){super(e,{useShadowDom:"pure"}),this.#o=h.WorkspaceDiff.workspaceDiff(),this.#i=i,this.requestUpdate()}performUpdate(){this.#i({workspaceDiff:this.#o,selectedSourceCode:this.#e,onSelect:e=>{this.#e=e,this.requestUpdate()}},{},this.contentElement)}wasShown(){n.Context.Context.instance().setFlavor(s,this),super.wasShown(),this.requestUpdate(),this.#o.addEventListener(h.WorkspaceDiff.Events.MODIFIED_STATUS_CHANGED,this.requestUpdate,this)}willHide(){super.willHide(),n.Context.Context.instance().setFlavor(s,null),this.#o.removeEventListener(h.WorkspaceDiff.Events.MODIFIED_STATUS_CHANGED,this.requestUpdate,this)}};export{q as ChangesSidebar,G as ChangesView,E as CombinedDiffView};
//# sourceMappingURL=changes.js.map
