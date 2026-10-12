# Makefile generator for big multi-module projects (ipab MANIFEST mode).
#
# Input: a TSV manifest, one library per line:
#   1 kind (swift_library|objc_library|cc_library)  2 label  3 module_name  4 srcs  5 hdrs  6 deps
#   7 copts  8 includes  9 defines  10 sdk_frameworks  11 sdk_dylibs  12 enable_modules  13 data
#   14 textual_hdrs  15 cxxopts  16 weak_sdk_frameworks  17 linkopts  18 package  19 alwayslink
# Paths: "pkg/file" (in SRCROOT), "@ext/<repo>/file" (EXT), "@gen/..." (GEN). File lists (srcs hdrs
# data textual_hdrs) are separated by "|", other lists by spaces.
#
# Variables (-v): SRCROOT EXT GEN B SWIFTC TCRES SDK MINIOS CACHE OPTC OPTS SWIFT_THREADS SWIFT_BATCH_JOBS ROOTS OUT RTOBJ LDID ENT LDFLAGS AR
#
# Output: Makefile on stdout (run with `make -C $SRCROOT`), plus module maps and output file maps under $B.
#   - ObjC / C / C++ files compile one object per source (-MMD header deps), never depend on Swift.
#   - A Swift module compiles in one swiftc call (-wmo, -num-threads), after the Swift modules and
#     the ObjC module maps it imports.
#   - Everything reachable from ROOTS is linked into $OUT.

BEGIN {
    FS = "\t"
    n = 0
}

{
    # undo the escaping of jq @tsv (\\ -> \), e.g. -DNAME=\"value\" in copts
    for (f = 1; f <= NF; f++) gsub(/\\\\/, "\\", $f)
    n++
    label = $2
    idx[label] = n
    L[n] = label
    kind[n] = $1
    modname[n] = $3
    srcs[n] = $4
    hdrs[n] = $5
    deps[n] = $6
    copts[n] = $7
    incs[n] = $8
    defs[n] = $9
    fws[n] = $10
    dylibs[n] = $11
    modules[n] = $12
    txthdrs[n] = $14
    cxxopts[n] = $15
    weakfws[n] = $16
    linkopts[n] = $17
    pkg[n] = $18
    alwayslink[n] = $19
}

function rp(p,    r, s, d) {
    if (substr(p, 1, 5) == "@gen/") r = GEN "/" substr(p, 6)
    else if (substr(p, 1, 5) == "@ext/") r = EXT "/" substr(p, 6)
    else r = SRCROOT "/" p
    # make can't handle spaces in file names: such files are used through a symlink
    if (r ~ / /) {
        s = r
        gsub(/ /, "_", s)
        s = B "/nospace" s
        if (!(s in nospace)) {
            nospace[s] = 1
            d = s
            sub(/\/[^\/]*$/, "", d)
            system("mkdir -p '" d "' && ln -sfn '" r "' '" s "'")
        }
        return s
    }
    return r
}


# Bazel tokenizes copts/defines with Bourne shell rules ("\"" -> ", quotes removed, spaces split);
# the resulting arguments are single-quoted again for the recipe (and $ doubled for make).
function shellargs(s,    i, c, n, tok, q, intok, out) {
    out = ""; tok = ""; q = ""; intok = 0; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "'") { if (c == "'") q = ""; else tok = tok c; continue }
        if (q == "\"") {
            if (c == "\"") { q = ""; continue }
            if (c == "\\" && i < n && index("\"\\$`", substr(s, i + 1, 1))) { i++; tok = tok substr(s, i, 1); continue }
            tok = tok c; continue
        }
        if (c == "\\" && i < n) { i++; tok = tok substr(s, i, 1); intok = 1; continue }
        if (c == "'" || c == "\"") { q = c; intok = 1; continue }
        if (c == " " || c == "\t") { if (intok) { out = out " " quote(tok); tok = ""; intok = 0 }; continue }
        tok = tok c; intok = 1
    }
    if (intok) out = out " " quote(tok)
    return out
}

function quote(t) {
    if (t ~ /^[A-Za-z0-9_@%+=:,.\/-]+$/) return t
    gsub(/'/, "'\\''", t)
    gsub(/\$/, "$$", t)
    return "'" t "'"
}

function sanitize(s,    r) {
    r = s
    gsub(/[^A-Za-z0-9_]/, "_", r)
    return r
}

# Directory of a package in the source tree / in the generated tree.
function pkgdir(i, gen,    lab, repo, p) {
    lab = L[i]
    p = pkg[i]
    if (substr(lab, 1, 1) == "@") {
        repo = lab
        sub(/^@@?/, "", repo)
        sub(/\/\/.*$/, "", repo)
        return (gen ? GEN "/@ext/" : EXT "/") repo (p == "" ? "" : "/" p)
    }
    return (gen ? GEN : SRCROOT) (p == "" ? "" : "/" p)
}

# Transitive dependencies (indices) as a space separated string, memoized.
function closure(i,    a, m, k, d, j, r, seen, out, parts, c, q) {
    if (i in tdeps) return tdeps[i]
    tdeps[i] = ""
    out = ""
    delete seen
    m = split(deps[i], a, " ")
    for (k = 1; k <= m; k++) {
        if (!(a[k] in idx)) continue
        d = idx[a[k]]
        if (!(d in seen)) { seen[d] = 1; out = out " " d }
        r = closure(d)
        c = split(r, parts, " ")
        for (q = 1; q <= c; q++) if (!(parts[q] in seen)) { seen[parts[q]] = 1; out = out " " parts[q] }
    }
    tdeps[i] = out
    return out
}

# directory containing a prebuilt <Name>.framework (for -F)
function fwparent(i,    d) {
    d = rp(srcs[i])
    sub(/\/[^\/]*$/, "", d)
    return d
}

# Big modules (debug): batch mode type-checks files on all cores (-wmo type-checks on one);
# small modules and release builds: whole-module.
function swiftmode(nsrc) {
    if (OPTS !~ /-Onone/ || nsrc < 150) return " -wmo -num-threads " SWIFT_THREADS
    return " -enable-batch-mode -j" SWIFT_BATCH_JOBS
}

function isswift(i) { return kind[i] == "swift_library" }
function iscfam(i) { return kind[i] == "objc_library" || kind[i] == "cc_library" }

# -I flags contributed by a C-family library (its `includes`, in source and generated trees).
function incflags(i,    a, m, k, d, out) {
    out = ""
    m = split(incs[i], a, " ")
    for (k = 1; k <= m; k++) {
        d = a[k]
        if (d == ".") d = ""
        out = out " -I" pkgdir(i, 0) (d == "" ? "" : "/" d) " -I" pkgdir(i, 1) (d == "" ? "" : "/" d)
    }
    return out
}

function defflags(i,    a, m, k, out) {
    out = ""
    m = split(defs[i], a, " ")
    for (k = 1; k <= m; k++) out = out shellargs("-D" a[k])
    return out
}

# Drops options that only make sense for Bazel or that turn this compiler's new warnings into errors.
function cleancopts(s,    a, m, k, out) {
    out = ""
    m = split(shellargs(s), a, " ")
    for (k = 1; k <= m; k++) {
        if (a[k] == "-warnings-as-errors" || a[k] == "-Werror" || a[k] == "") continue
        out = out " " a[k]
    }
    return out
}

function modmap(i) { return B "/modulemaps/" modname[i] ".modulemap" }

function writemodmap(i,    f, a, m, k) {
    # written via .tmp + cmp: an unchanged map keeps its mtime (Swift modules depend on it)
    f = modmap(i) ".tmp"
    printf "module \"%s\" {\n    export *\n", modname[i] > f
    m = split(hdrs[i], a, "|")
    for (k = 1; k <= m; k++) if (a[k] ~ /\.(h|hh|hpp)$/) printf "    header \"%s\"\n", rp(a[k]) > f
    m = split(txthdrs[i], a, "|")
    for (k = 1; k <= m; k++) printf "    textual header \"%s\"\n", rp(a[k]) > f
    print "}" > f
    close(f)
    system("cmp -s '" f "' '" modmap(i) "' && rm -f '" f "' || mv -f '" f "' '" modmap(i) "'")
}

END {
    # --- what to build: everything reachable from ROOTS
    m = split(ROOTS, r, " ")
    for (k = 1; k <= m; k++) {
        if (!(r[k] in idx)) { print "manifest.awk: no root " r[k] > "/dev/stderr"; exit 1 }
        i = idx[r[k]]
        want[i] = 1
        c = split(closure(i), parts, " ")
        for (q = 1; q <= c; q++) want[parts[q]] = 1
    }

    system("mkdir -p " B "/modulemaps " B "/swift " B "/link")

    for (i = 1; i <= n; i++) {
        if (!(i in want)) continue
        if (kind[i] == "objc_library" && modname[i] != "" && hdrs[i] != "") { hasmap[i] = 1; writemodmap(i) }
    }

    print ".SUFFIXES:"
    print "OBJ :="
    print "all: " OUT
    print ""

    linklist = ""
    swiftstamps = ""
    for (i = 1; i <= n; i++) {
        if (!(i in want)) continue
        id = sanitize(L[i])
        td = closure(i)
        c = split(td, tparts, " ")

        # Context from dependencies: include dirs, defines, module maps (C family only).
        ctx = ""
        maps = ""
        mapfiles = ""
        fwctx = ""
        for (q = 1; q <= c; q++) {
            d = tparts[q]
            if (kind[d] == "xcframework") { fwctx = fwctx " -F" fwparent(d); continue }
            if (!iscfam(d)) continue
            ctx = ctx incflags(d) defflags(d)
            if (d in hasmap) { maps = maps " -fmodule-map-file=" modmap(d); mapfiles = mapfiles " " modmap(d) }
        }

        if (kind[i] == "xcframework") {
            linklist = linklist " " rp(srcs[i]) "/" modname[i]
            linkfw = linkfw " -F" fwparent(i)
            continue
        }
        if (iscfam(i)) {
            base = "-target arm64-apple-ios" MINIOS " -isysroot " SDK " " OPTC " -iquote " SRCROOT " -iquote " GEN " -MMD -MP"
            own = incflags(i) defflags(i) ctx fwctx
            objc = kind[i] == "objc_library"
            mods = ""
            # Module maps of dependencies are for Swift only: C-family code includes their headers
            # textually (building a module from every header of a C++ library fails).
            if (objc && modules[i] == "1") mods = " -fmodules -fmodules-cache-path=" CACHE "/clang"
            co = cleancopts(copts[i])
            cxo = cleancopts(cxxopts[i])
            libobjs = ""
            ms = split(srcs[i], sa, "|")
            for (k = 1; k <= ms; k++) {
                s = sa[k]
                if (s ~ /\.a$/) { linklist = linklist " " rp(s); continue }
                if (s !~ /\.(c|m|mm|cc|cpp|cxx|S|s)$/) continue
                src = rp(s)
                o = B "/o/" id "/" s ".o"
                gsub(/[@ ]/, "_", o)
                lang = ""
                cc = "clang"
                if (s ~ /\.c$/) lang = ""
                else if (s ~ /\.m$/) lang = objc ? " -fobjc-arc" : ""
                else if (s ~ /\.mm$/) { cc = "clang++"; lang = " -std=c++17" (objc ? " -fobjc-arc" : "") }
                else if (s ~ /\.(S|s)$/) lang = ""
                else { cc = "clang++"; lang = " -std=c++17" }
                extra = (cc == "clang++") ? cxo : ""
                print o ": " src " " B "/cflags.stamp"
                print "\t@echo '  CC     " s "'"
                print "\t@mkdir -p $(dir $@)"
                # clang modules only for ObjC: in ObjC++ (with C++20+) they hide parts of Foundation
                print "\t@" cc " " base lang (s ~ /\.m$/ ? mods : "") own " " co extra " -c " src " -o $@"
                print "-include " substr(o, 1, length(o) - 2) ".d"
                libobjs = libobjs " " o
            }
            # Static archive of this library alone (what Bazel's $(location <cc_library>) gives genrules).
            # Linked like Bazel does: as an archive (only referenced members are loaded, -ObjC loads
            # ObjC classes/categories), alwayslink libraries entirely.
            if (libobjs != "") {
                # object list in a response file: WebRTC has thousands of objects (argument list too long)
                lst = B "/libs/" id ".objs"
                system("mkdir -p '" B "/libs'")
                nobj = split(libobjs, oa, " ")
                printf "" > (lst ".tmp")
                for (q = 1; q <= nobj; q++) print oa[q] > (lst ".tmp")
                close(lst ".tmp")
                system("cmp -s '" lst ".tmp' '" lst "' && rm -f '" lst ".tmp' || mv -f '" lst ".tmp' '" lst "'")
                print B "/libs/" id ".a:" libobjs " " lst
                print "\t@rm -f $@ && " AR " rcs $@ @" lst
                if (alwayslink[i] == "1") forceload = forceload " -Wl,-force_load," B "/libs/" id ".a"
                else archives = archives " " B "/libs/" id ".a"
            }
            for (q = 1; q <= split(fws[i], fa, " "); q++) frameworks[fa[q]] = 1
            for (q = 1; q <= split(weakfws[i], fa, " "); q++) weakframeworks[fa[q]] = 1
            for (q = 1; q <= split(dylibs[i], fa, " "); q++) libs[fa[q]] = 1
            linkflags = linkflags " " linkopts[i]
        } else if (isswift(i)) {
            mname = modname[i] != "" ? modname[i] : sanitize(substr(L[i], index(L[i], ":") + 1))
            stamp = B "/swift/" id ".stamp"
            ofm = B "/swift/" id ".json"
            dir = B "/so/" id
            srclist = ""
            objlist = ""
            depfiles = ""
            ofmfinal = ofm
            ofm = ofm ".tmp"
            printf "{\"\":{\"swift-dependencies\":\"%s/master.swiftdeps\"}", dir > ofm
            ms = split(srcs[i], sa, "|")
            for (k = 1; k <= ms; k++) {
                if (sa[k] !~ /\.swift$/) continue
                src = rp(sa[k])
                o = dir "/" k ".o"
                printf ",\n\"%s\":{\"object\":\"%s\"}", src, o > ofm
                srclist = srclist " " src
                objlist = objlist " " o
                linklist = linklist " " o
            }
            print "}" > ofm
            close(ofm)
            system("cmp -s '" ofm "' '" ofmfinal "' && rm -f '" ofm "' || mv -f '" ofm "' '" ofmfinal "'")
            ofm = ofmfinal
            nsrc = split(srclist, tmpsrc, " ")
            if (srclist == "") continue
            for (q = 1; q <= c; q++) {
                d = tparts[q]
                if (isswift(d)) depfiles = depfiles " " B "/swift/" sanitize(L[d]) ".stamp"
            }
            # Clang options for the imported C-family modules.
            xcc = ""
            nx = split(ctx fwctx maps " -iquote " SRCROOT " -iquote " GEN, xa, " ")
            for (q = 1; q <= nx; q++) if (xa[q] != "") xcc = xcc " -Xcc " xa[q]
            print stamp ":" srclist " " B "/swflags.stamp" depfiles mapfiles
            print "\t@echo '  SWIFT  " mname "'"
            print "\t@mkdir -p " dir " " B "/mods"
            print "\t@" SWIFTC " -c -parse-as-library -module-name " mname " -emit-module-path " B "/mods/" mname ".swiftmodule" \
                  " -output-file-map " ofm " " OPTS swiftmode(nsrc) \
                  " -sdk " SDK " -target arm64-apple-ios" MINIOS " -resource-dir " TCRES \
                  " -module-cache-path " CACHE "/swift -runtime-compatibility-version none -Xfrontend -enable-cross-import-overlays -I " B "/mods" fwctx \
                  cleancopts(copts[i]) xcc srclist
            print "\t@touch $@"
            # The objects are produced by the module's swiftc call.
            print substr(objlist, 2) ": " stamp " ;"
            swiftstamps = swiftstamps " " stamp
            if (srclist != "") hasswift = 1
        }
    }

    # --- link
    rsp = B "/link/objects.rsp"
    nl = split(linklist, la, " ")
    printf "" > rsp
    for (k = 1; k <= nl; k++) print la[k] > rsp
    na = split(archives, aa, " ")
    for (k = 1; k <= na; k++) print aa[k] > rsp
    close(rsp)
    fl = ""
    for (f in frameworks) fl = fl " -framework " f
    for (f in weakframeworks) fl = fl " -weak_framework " f
    for (f in libs) fl = fl " -l" f
    print "OBJECTS :=" linklist archives
    nf = split(forceload, fa2, " ")
    for (k = 1; k <= nf; k++) { x = fa2[k]; sub(/^-Wl,-force_load,/, "", x); print "OBJECTS += " x }
    print OUT ": $(OBJECTS)" swiftstamps " " RTOBJ " " B "/ldflags.stamp"
    print "\t@echo '  LD     " OUT "'"
    print "\t@clang++ -target arm64-apple-ios" MINIOS " -isysroot " SDK " -fuse-ld=lld @" rsp " " RTOBJ \
          " -L" SDK "/usr/lib/swift -Wl,-rpath,/usr/lib/swift -Wl,-rpath,@executable_path/Frameworks" \
          " -ObjC" forceload linkfw fl " " linkflags " " LDFLAGS " -o $@"
    if (LDID != "") print "\t@" LDID " -S" ENT " $@"
}
