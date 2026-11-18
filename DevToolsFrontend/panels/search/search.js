var ee=Object.defineProperty;var V=(o,e)=>{for(var t in e)ee(o,t,{get:e[t],enumerable:!0})};var H={};V(H,{DEFAULT_VIEW:()=>K,SearchResultsPane:()=>x,lineSegmentForMatch:()=>O,matchesExpandedByDefault:()=>F,matchesShownAtOnce:()=>q});import*as P from"../../core/common/common.js";import*as L from"../../core/i18n/i18n.js";import*as D from"../../core/platform/platform.js";import*as R from"../../core/text_utils/text_utils.js";import*as C from"../../ui/legacy/legacy.js";import{html as y,render as te}from"../../ui/lit/lit.js";var W=`:host{padding:0;margin:0;overflow-y:auto}.tree-outline{padding:0}.tree-outline ol{padding:0}.tree-outline li{height:var(--sys-size-8)}li.search-result{cursor:pointer;font-size:var(--sys-typescale-body4-size);margin-top:var(--sys-size-5);padding:var(--sys-size-2) 0 var(--sys-size-2) var(--sys-size-3);overflow-wrap:normal;white-space:pre}li.search-result .tree-element-title{display:flex;width:100%}li.search-result:hover{background-color:var(--sys-color-state-hover-on-subtle)}li.search-result .search-result-file-name{color:var(--sys-color-on-surface);flex:1 1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}li.search-result .search-result-matches-count{color:var(--sys-color-token-subtle);margin:0 var(--sys-size-5)}li.search-result.expanded .search-result-matches-count{display:none}li.show-more-matches{color:var(--sys-color-on-surface);cursor:pointer;margin:var(--sys-size-5) 0 0 calc(-1 * var(--sys-size-3))}li.show-more-matches:hover{text-decoration:underline}li.search-match{margin:var(--sys-size-2) 0;overflow-wrap:normal;white-space:pre}li.search-match .tree-element-title{display:flex}li.search-match.selected:focus-visible{background:var(--sys-color-tonal-container)}li.search-match::before{display:none}li.search-match .search-match-line-number{color:var(--sys-color-token-subtle);text-align:right;vertical-align:top;word-break:normal;padding:var(--sys-size-2) var(--sys-size-3) var(--sys-size-2) var(--sys-size-4);margin-right:5px}.tree-outline .devtools-link{text-decoration:none;display:block;flex:auto}li.search-match .search-match-content{color:var(--sys-color-on-surface)}ol.children.expanded{padding-bottom:var(--sys-size-3)}li.search-match .link-style.search-match-link{overflow:hidden;text-overflow:ellipsis;margin-left:9px;text-align:left}.search-result-qualifier{color:var(--sys-color-token-subtle)}.search-result-dash{color:var(--sys-color-surface-variant);margin:0 var(--sys-size-3)}
/*# sourceURL=${import.meta.resolve("./searchResultsPane.css")} */`;var k={matchesCountS:"Matches count {PH1}",lineS:"Line {PH1}",showDMore:"Show {PH1} more"},se=L.i18n.registerUIStrings("panels/search/SearchResultsPane.ts",k),$=L.i18n.getLocalizedString.bind(void 0,se),{ifExpanded:oe}=C.TreeOutline,K=(o,e,t)=>{let{results:r,matches:s,expandedResults:c,onSelectMatch:u,onExpandSearchResult:h,onShowMoreMatches:n}=o,d=(l,{detail:{expanded:p}})=>{p?(c.add(l),h(l)):c.delete(l)};te(y`
    <devtools-tree hide-overflow .template=${y`
      <ul role="tree">
        ${r.map(l=>y`
          <li @expand=${p=>d(l,p)}
              role="treeitem"
              class="search-result"
              ?open=${c.has(l)}>
            <style>${W}</style>
            ${re(l)}
            <ul role="group">
              ${oe(ie(l,s,u,n))}
            </ul>
          </li>`)}
      </ul>
    `}></devtools-tree>`,t)},re=o=>y`
    <span class="search-result-file-name">${o.label()}
      <span class="search-result-dash">${"\u2014"}</span>
      <span class="search-result-qualifier">${o.description()}</span>
    </span>
    <span class="search-result-matches-count"
        aria-label=${$(k.matchesCountS,{PH1:o.matchesCount()})}>
        ${o.matchesCount()}
    </span>`,ie=(o,e,t,r)=>{let s=e.get(o)??[],c=o.matchesCount()-s.length;return y`
      ${s.map(({lineContent:u,matchRanges:h,resultLabel:n},d)=>y`
        <li role="treeitem" class="search-match" @click=${()=>t(o,d)}
          @keydown=${l=>{l.key==="Enter"&&t(o,d)}}
        >
          <button class="devtools-link text-button link-style search-match-link"
                  jslog="Link; context: search-match; track: click" role="link" tabindex="0"
                  @click=${()=>{P.Revealer.reveal(o.matchRevealable(d))}}>
            <span class="search-match-line-number"
                aria-label=${typeof n=="number"&&!isNaN(n)?$(k.lineS,{PH1:n}):n}>
              ${n}
            </span>
            <span class="search-match-content" aria-label="${u} line"
                  ${C.TreeOutline.TreeSearch.highlight(h,void 0)}>
              ${u}
            </span>
          </button>
        </li>`)}
      ${c>0?y`
        <li role="treeitem" class="show-more-matches" @click=${()=>r(o)}>
          ${$(k.showDMore,{PH1:c})}
        </li>`:""}`},x=class extends C.Widget.VBox{#r=null;#t=[];#n=!1;#i=new WeakSet;#s=new WeakMap;#a;constructor(e,t=K){super(e,{useShadowDom:!0}),this.#a=t}get searchResults(){return this.#t}set searchResults(e){if(this.#t!==e){if(this.#t.length!==e.length)this.#n=!0;else if(this.#t.length===e.length){for(let t=0;t<this.#t.length;++t)if(this.#t[t]!==e[t]){this.#n=!0;break}}this.#n&&(this.#t=e,this.requestUpdate())}}get searchConfig(){return this.#r}set searchConfig(e){this.#r=e,this.requestUpdate()}showAllMatches(){for(let e of this.#t){let t=this.#s.get(e)?.length??0;this.#l(e,t,e.matchesCount()),this.#i.add(e)}this.requestUpdate()}collapseAllResults(){this.#i=new WeakSet,this.requestUpdate()}#o(e){let t=Math.min(e.matchesCount(),q);this.#l(e,0,t),this.requestUpdate()}#l(e,t,r){if(!this.#r)return;let s=this.#r.queries(),c=[];for(let h=0;h<s.length;++h)c.push(D.StringUtilities.createSearchRegex(s[h],!this.#r.ignoreCase(),this.#r.isRegex()));let u=this.#s.get(e)??[];if(this.#s.set(e,u),!(u.length>=r))for(let h=t;h<r;++h){let n=e.matchLineContent(h),d=[],l=e.matchColumn(h),p=e.matchLength(h);if(l!==void 0&&p!==void 0){let{matchRange:m,lineSegment:T}=O(n,new R.TextRange.SourceRange(l,p));n=T,d=[m]}else{n=n.trim();for(let m=0;m<c.length;++m)d=d.concat(this.#h(n,c[m]));({lineSegment:n,matchRanges:d}=ae(n,d))}let w=e.matchLabel(h);u.push({lineContent:n,matchRanges:d,resultLabel:w})}}performUpdate(){if(this.#n){let e=0;for(let t of this.#t)this.#i.has(t)&&(e+=this.#s.get(t)?.length??0);for(let t of this.#t)e<F&&!this.#i.has(t)&&(this.#i.add(t),this.#o(t),e+=this.#s.get(t)?.length??0);this.#n=!1}this.#a({results:this.#t,matches:this.#s,expandedResults:this.#i,onSelectMatch:(e,t)=>{P.Revealer.reveal(e.matchRevealable(t))},onExpandSearchResult:this.#o.bind(this),onShowMoreMatches:this.#m.bind(this)},{},this.contentElement)}#h(e,t){t.lastIndex=0;let r,s=[];for(;t.lastIndex<e.length&&(r=t.exec(e));)s.push(new R.TextRange.SourceRange(r.index,r[0].length));return s}#m(e){let t=this.#s.get(e)?.length??0;this.#l(e,t,e.matchesCount()),this.requestUpdate()}},F=200,q=20,A={prefixLength:25,maxLength:1e3};function O(o,e,t=A){let r={...A,...t},s=o.trimStart(),c=o.length-s.length,u=Math.min(e.offset,c),h=Math.max(u,e.offset-r.prefixLength),n=Math.min(o.length,h+r.maxLength),d=h>u?"\u2026":"",l=d+o.substring(h,n),p=e.offset-h+d.length,w=Math.min(e.length,l.length-p),m=new R.TextRange.SourceRange(p,w);return{lineSegment:l,matchRange:m}}function ae(o,e){let t=0,r=e;r.length>0&&r[0].offset>20&&(t=15);let s=o.substring(t,1e3+t);return t&&(r=r.map(c=>new R.TextRange.SourceRange(c.offset-t+1,c.length)),s="\u2026"+s),{lineSegment:s,matchRanges:r}}var ne={};var G={};V(G,{DEFAULT_VIEW:()=>_,SearchView:()=>B});import"../../ui/legacy/legacy.js";import"../../ui/kit/kit.js";import*as b from"../../core/common/common.js";import*as Q from"../../core/host/host.js";import*as z from"../../core/i18n/i18n.js";import*as I from"../../models/workspace/workspace.js";import*as f from"../../ui/components/buttons/buttons.js";import*as g from"../../ui/legacy/legacy.js";import{Directives as le,html as E,render as he}from"../../ui/lit/lit.js";import*as v from"../../ui/visual_logging/visual_logging.js";var j=`.search-drawer-header{flex-shrink:0;overflow:hidden;display:inline-flex;min-width:150px;.search-container{border-bottom:var(--sys-size-1) solid var(--sys-color-divider);display:flex;align-items:center;flex-grow:1}.toolbar-item-search{flex-grow:1;box-shadow:inset 0 0 0 var(--sys-size-2) transparent;box-sizing:border-box;height:var(--sys-size-9);margin-left:var(--sys-size-3);padding:0 var(--sys-size-2) 0 var(--sys-size-5);border-radius:var(--sys-shape-corner-full);position:relative;display:flex;align-items:center;background-color:var(--sys-color-cdt-base);&:has(input:focus){box-shadow:inset 0 0 0 var(--sys-size-2) var(--sys-color-state-focus-ring)}&:has(input:hover)::before{content:"";box-sizing:inherit;height:100%;width:100%;position:absolute;border-radius:var(--sys-shape-corner-full);left:0;background-color:var(--sys-color-state-hover-on-subtle)}& > devtools-icon{color:var(--sys-color-on-surface-subtle);width:var(--sys-size-8);height:var(--sys-size-8);margin-right:var(--sys-size-3)}& > devtools-button:last-child{margin-right:var(--sys-size-4)}}.search-toolbar-input{appearance:none;color:var(--sys-color-on-surface);background-color:transparent;border:0;z-index:1;flex:1;&::placeholder{color:var(--sys-color-on-surface-subtle)}&:placeholder-shown + .clear-button{display:none}&::-webkit-search-cancel-button{display:none}}}.search-toolbar{background-color:var(--sys-color-cdt-base-container);border-bottom:var(--sys-size-1) solid var(--sys-color-divider)}.search-toolbar-summary{background-color:var(--sys-color-cdt-base-container);border-top:var(--sys-size-1) solid var(--sys-color-divider);padding-left:5px;flex:0 0 19px;display:flex;padding-right:5px}.search-results:has(.empty-widget-container) + .search-toolbar-summary{display:none}.search-toolbar-summary .search-message{padding-top:var(--sys-size-2);padding-left:1ex;text-overflow:ellipsis;white-space:nowrap;overflow:hidden}.search-results{overflow-y:auto;display:flex;flex:auto}.search-results > div{flex:auto}
/*# sourceURL=${import.meta.resolve("./searchView.css")} */`;var i={find:"Find",enableCaseSensitive:"Enable case sensitive search",disableCaseSensitive:"Disable case sensitive search",enableRegularExpression:"Enable regular expressions",disableRegularExpression:"Disable regular expressions",refresh:"Refresh",clearInput:"Clear",clear:"Clear search",indexing:"Indexing\u2026",searching:"Searching\u2026",indexingInterrupted:"Indexing interrupted",foundMatchingLineInFile:"Found 1 matching line in 1 file",foundDMatchingLinesInFile:"Found {PH1} matching lines in 1 file",foundDMatchingLinesInDFiles:"Found {PH1} matching lines in {PH2} files",noMatchesFound:"No matches found",nothingMatchedTheQuery:"Nothing matched your search query",searchFinished:"Search finished",searchInterrupted:"Search interrupted",typeAndPressSToSearch:"Type and press {PH1} to search",noSearchResult:"No search results"},ce=z.i18n.registerUIStrings("panels/search/SearchView.ts",i),a=z.i18n.getLocalizedString.bind(void 0,ce),{ref:de,live:ue}=le,{widget:N,widgetRef:ge}=g.Widget,_=(o,e,t)=>{let{query:r,matchCase:s,isRegex:c,searchConfig:u,searchMessage:h,searchResults:n,searchResultsMessage:d,progress:l,onQueryChange:p,onQueryKeyDown:w,onPanelKeyDown:m,onClearSearchInput:T,onToggleRegex:Y,onToggleMatchCase:J,onRefresh:X,onClearSearch:Z}=o,M="",U="";r?l?M=a(i.searching):n.length||(M=a(i.noMatchesFound),U=a(i.nothingMatchedTheQuery)):(M=a(i.noSearchResult),U=a(i.typeAndPressSToSearch,{PH1:g.KeyboardShortcut.KeyboardShortcut.shortcutToString(g.KeyboardShortcut.Keys.Enter)})),he(E`
      <style>${g.inspectorCommonStyles}</style>
      <style>${j}</style>
      <div class="search-drawer-header" @keydown=${m}>
        <div class="search-container">
          <div class="toolbar-item-search">
            <devtools-icon name="search"></devtools-icon>
            <input type="text"
                class="search-toolbar-input"
                placeholder=${a(i.find)}
                jslog=${v.textField().track({change:!0,keydown:"ArrowUp|ArrowDown|Enter"})}
                aria-label=${a(i.find)}
                size="100" results="0"
                .value=${ue(r)}
                @keydown=${w}
                @input=${S=>p(S.target.value)}
                ${de(S=>{e.focusSearchInput=()=>{S instanceof HTMLInputElement&&(S.focus(),S.select())}})}>
            <devtools-button class="clear-button" tabindex="-1"
                @click=${T}
                .data=${{variant:f.Button.Variant.ICON,iconName:"cross-circle-filled",jslogContext:"clear-input",size:f.Button.Size.SMALL,title:a(i.clearInput)}}
            ></devtools-button>
            <devtools-button @click=${Y} .data=${{variant:f.Button.Variant.ICON_TOGGLE,iconName:"regular-expression",toggledIconName:"regular-expression",toggleType:f.Button.ToggleType.PRIMARY,size:f.Button.Size.SMALL,toggled:c,title:a(c?i.disableRegularExpression:i.enableRegularExpression),jslogContext:"regular-expression"}}
              class="regex-button"
            ></devtools-button>
            <devtools-button @click=${J} .data=${{variant:f.Button.Variant.ICON_TOGGLE,iconName:"match-case",toggledIconName:"match-case",toggleType:f.Button.ToggleType.PRIMARY,size:f.Button.Size.SMALL,toggled:s,title:a(s?i.disableCaseSensitive:i.enableCaseSensitive),jslogContext:"match-case"}}
              class="match-case-button"
            ></devtools-button>
          </div>
        </div>
        <devtools-toolbar class="search-toolbar" jslog=${v.toolbar()}>
          <devtools-button title=${a(i.refresh)} @click=${X}
              .data=${{variant:f.Button.Variant.TOOLBAR,iconName:"refresh",jslogContext:"search.refresh"}}></devtools-button>
          <devtools-button title=${a(i.clear)} @click=${Z}
              .data=${{variant:f.Button.Variant.TOOLBAR,iconName:"clear",jslogContext:"search.clear"}}></devtools-button>
        </devtools-toolbar>
      </div>
      <div class="search-results" @keydown=${m}>
        ${n.length?E`<devtools-widget ${N(x,{searchResults:n,searchConfig:u})}
            ${ge(x,S=>{e.showAllMatches=()=>{S.showAllMatches()},e.collapseAllResults=()=>{S.collapseAllResults()}})}>
            </devtools-widget>`:N(g.EmptyWidget.EmptyWidget,{header:M,text:U})}
      </div>
      <div class="search-toolbar-summary" @keydown=${m}>
        <div class="search-message">${h}</div>
        <div class="flex-centered">
          ${l?E`
            <devtools-progress .title=${l.title??""}
                               .worked=${l.worked} .totalWork=${l.totalWork}>
            </devtools-progress>`:""}
        </div>
        <div class="search-message">${d}</div>
      </div>`,t,{container:{attributes:{jslog:`${v.panel("search").track({resize:!0})}`}}})},B=class extends g.Widget.VBox{#r;#t=()=>{};#n=()=>{};#i=()=>{};#s;#a;#o;#l;#h;#m;#y;#p;#e;#d;#f=!1;#v=!1;#u="";#g="";#b;#c;#S=[];constructor(e,t=_){super({useShadowDom:"pure"}),this.#r=t,this.setMinimumSize(0,40),this.#s=!1,this.#a=1,this.#d="",this.#o=0,this.#l=0,this.#h=0,this.#m=null,this.#y=null,this.#p=null,this.#e=null,this.#b=b.Settings.Settings.instance().createLocalSetting(e+"-search-config",new I.SearchConfig.SearchConfig("",!0,!1).toPlainObject()),this.performUpdate(),this.#F(),this.performUpdate(),this.#c=null}performUpdate(){let e={query:this.#d,matchCase:this.#f,isRegex:this.#v,searchConfig:this.#y,searchMessage:this.#u,searchResults:this.#S.filter(s=>s.matchesCount()),searchResultsMessage:this.#g,progress:this.#e,onQueryChange:s=>{this.#d=s},onQueryKeyDown:this.#D.bind(this),onPanelKeyDown:this.#K.bind(this),onClearSearchInput:this.#k.bind(this),onToggleRegex:this.#P.bind(this),onToggleMatchCase:this.#L.bind(this),onRefresh:this.#x.bind(this),onClearSearch:this.#q.bind(this)},t=this,r={set focusSearchInput(s){t.#t=s},set showAllMatches(s){t.#n=s},set collapseAllResults(s){t.#i=s}};this.#r(e,r,this.contentElement)}#P(){this.#v=!this.#v,this.performUpdate()}#L(){this.#f=!this.#f,this.performUpdate()}#w(){return new I.SearchConfig.SearchConfig(this.#d,!this.#f,this.#v)}toggle(e,t){this.#d=e,this.requestUpdate(),this.updateComplete.then(()=>{this.focus()}),this.#R(),t?this.#x():this.#M()}createScope(){throw new Error("Not implemented")}#R(){this.#c=this.createScope()}#C(){if(!this.#e)return;let e=!this.#e.canceled;if(this.#e=null,this.#s=!1,this.#u=e?"":a(i.indexingInterrupted),e||(this.#p=null),this.performUpdate(),!this.#p)return;let t=this.#p;this.#p=null,this.#z(t)}#M(){this.#s=!0,this.#e&&(this.#e.done=!0),this.#e=new b.Progress.ProgressProxy(new b.Progress.Progress,this.#C.bind(this),this.requestUpdate.bind(this)),this.#u=a(i.indexing),this.performUpdate(),this.#c&&this.#c.performIndexing(this.#e)}#k(){this.#d="",this.requestUpdate(),this.#$(),this.focus()}#E(e,t){if(!(e!==this.#a||!this.#e)){if(this.#e?.canceled){this.#C();return}this.#S.push(t),this.#W(t),this.requestUpdate()}}#B(e,t){e!==this.#a||!this.#e||(this.#e=null,this.#A(t),g.ARIAUtils.LiveAnnouncer.alert(this.#u+" "+this.#g))}#z(e){this.#y=e,this.#e&&(this.#e.done=!0),this.#e=new b.Progress.ProgressProxy(new b.Progress.Progress,void 0,this.requestUpdate.bind(this)),this.#V(),this.#c&&this.#c.performSearch(e,this.#e,this.#E.bind(this,this.#a),this.#B.bind(this,this.#a))}#I(){this.#T(),this.#S=[],this.#u="",this.#g="",this.performUpdate()}#T(){this.#e&&!this.#s&&(this.#e.canceled=!0),this.#c&&this.#c.stopSearch()}#V(){this.#o=0,this.#l=0,this.#S=[],this.#h=0,this.#m||(this.#m=new g.EmptyWidget.EmptyWidget(a(i.searching),"")),this.#u=a(i.searching),this.performUpdate(),this.#U()}#U(){this.#o&&this.#l?this.#o===1&&this.#h===1?this.#g=a(i.foundMatchingLineInFile):this.#o>1&&this.#h===1?this.#g=a(i.foundDMatchingLinesInFile,{PH1:this.#o}):this.#g=a(i.foundDMatchingLinesInDFiles,{PH1:this.#o,PH2:this.#h}):this.#g="",this.performUpdate()}#W(e){let t=e.matchesCount();this.#o+=t,this.#l++,t&&this.#h++,this.#U()}#A(e){this.#u=a(e?i.searchFinished:i.searchInterrupted),this.requestUpdate()}focus(){this.#t()}willHide(){super.willHide(),this.#T()}#D(e){this.#$(),e.keyCode===g.KeyboardShortcut.Keys.Enter.code&&this.#x()}#K(e){let t=Q.Platform.isMac(),r=t&&e.metaKey&&!e.ctrlKey&&e.altKey&&e.code==="BracketRight",s=!t&&e.ctrlKey&&!e.metaKey&&e.shiftKey&&e.code==="BracketRight",c=t&&e.metaKey&&!e.ctrlKey&&e.altKey&&e.code==="BracketLeft",u=!t&&e.ctrlKey&&!e.metaKey&&e.shiftKey&&e.code==="BracketLeft";r||s?(this.#n(),v.logKeyDown(e.currentTarget,e,"show-all-matches")):(c||u)&&(this.#i(),v.logKeyDown(e.currentTarget,e,"collapse-all-results"))}#$(){this.#b.set(this.#w().toPlainObject())}#F(){let e=I.SearchConfig.SearchConfig.fromPlainObject(this.#b.get());this.#d=e.query(),this.#f=!e.ignoreCase(),this.#v=e.isRegex(),this.requestUpdate()}#x(){let e=this.#w();e.query()?.length&&(this.#I(),++this.#a,this.#R(),this.#s||this.#M(),this.#p=e)}#q(){this.#I(),this.#k()}};export{H as SearchResultsPane,ne as SearchScope,G as SearchView};
//# sourceMappingURL=search.js.map
