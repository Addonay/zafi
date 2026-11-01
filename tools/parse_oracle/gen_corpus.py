#!/usr/bin/env python3
"""Generates corpus.txt for the parse oracle: `Type<TAB>input` per line."""
import itertools

KEYWORDS = ["auto", "none", "block", "flex", "grid", "flow-root", "contents", "inline", "relative", "absolute",
            "fixed", "static", "sticky", "border-box", "content-box", "visible", "hidden", "clip", "scroll", "ltr",
            "rtl", "size", "layout", "paint", "inline-size", "strict", "content", "style", "nowrap", "wrap",
            "wrap-reverse", "balance", "row", "column", "row-reverse", "column-reverse", "left", "right", "center",
            "legacy-left", "legacy-right", "legacy-center", "both", "inline-start", "inline-end", "start", "end",
            "flex-start", "flex-end", "self-start", "self-end", "baseline", "stretch", "normal", "space-between",
            "space-around", "space-evenly", "dense", "min-content", "max-content", "fit-content", "safe center",
            "unsafe end", "safe", "first baseline", "last baseline", "safe stretch", "unsafe space-between",
            "row dense", "column dense", "dense row", "dense column", "dense dense", "row column", "inherit", "initial",
            "-webkit-left", "-webkit-right", "-webkit-center", "-WEBKIT-LEFT", "layout paint", "paint layout",
            "layout paint style", "style", "layout layout", "none layout", "content paint", "wrap balance",
            "balance wrap-reverse", "balance", "balance balance", "nowrap balance", "wrap wrap", "safe flex-end",
            "unsafe self-start", "SAFE CENTER", "safe normal", "unsafe baseline", "safe space-around"]

def mutations(s):
    out = {s, " " + s, s + " ", "  " + s + "\x0c", s.upper(), s.capitalize(), "/* c */" + s, s + "/* c */",
           s + " x", s + ",", s + ";"}
    return out

NUMS = ["0", "1", "10", "-5", "+5", "1.5", ".5", "-.5", "1e2", "1E2", "1e-1", "0.0", "-0", "1.", "99999999999"]
UNITS = ["px", "PX", "Px", "%", "em", "fr", "", "rem", "pt"]
LENGTHS = [n + u for n in NUMS for u in UNITS]

TRACK_EXTRA = ["fit-content(10px)", "fit-content(50%)", "fit-content( 10px )", "fit-content(10px", "fit-content()",
               "fit-content(auto)", "fit-content(1fr)", "fit-content(10)", "minmax(10px, 1fr)", "minmax(10px,1fr)",
               "minmax( 10px , 20% )", "minmax(auto, auto)", "minmax(min-content, max-content)",
               "minmax(1fr, 10px)", "minmax(10px)", "minmax(10px, 1fr, 2fr)", "minmax(fit-content(10px), 1fr)",
               "minmax(10px, fit-content(10px))", "MINMAX(10px, 1fr)", "minmax (10px, 1fr)", "calc(10px)",
               "repeat(2, 10px)", "1fr", "0fr", "-1fr", "2.5fr", "auto", "min-content", "max-content", "10px 20px"]

REPEAT = ["repeat(2, 10px)", "repeat(2,10px)", "repeat( 3 , 1fr 2fr )", "repeat(auto-fill, 10px)",
          "repeat(auto-fit, minmax(10px, 1fr))", "repeat(0, 10px)", "repeat(-1, 10px)", "repeat(1.5, 10px)",
          "repeat(65536, 1px)", "repeat(2)", "repeat(2,)", "repeat(, 10px)", "repeat(2, [a] 10px [b])",
          "repeat(2, [a b] 10px [c] 20px)", "repeat(2, repeat(2, 10px))", "repeat(auto-fill, 1fr)",
          "repeat(AUTO-FILL, 10px)", "repeat(2 10px)", "REPEAT(2, 10px)", "repeat(2, 10px", "repeat(2, [a])",
          "repeat(2, 10px [a] [b])"]

TEMPLATE = ["10px", "10px 20px", "[a] 10px", "10px [a]", "[a] 10px [b] 20px [c]", "[a b] 10px", "[] 10px",
            "[a] [b] 10px", "10px [a", "10px a]", "[a]", "", "  10px   1fr  ", "repeat(2, 10px) 1fr",
            "[a] repeat(2, [b] 10px) [c]", "minmax(10px, 1fr) auto", "fit-content(10px) 1fr", "10px, 20px",
            "[1] 10px", "[a-b_c] 10px", "[span] 10px", "[auto] 10px", "10px\x0c20px", "10px/* c */20px",
            "[ a ] 10px", "[a]10px[b]", "repeat(auto-fill, 10px) repeat(auto-fill, 20px)"]

PLACEMENT = ["auto", "1", "-1", "0", "3", "+2", "1.5", "span 2", "span", "span 0", "span -1", "2 span",
             "span a", "a span", "a", "a 2", "2 a", "span 2 a", "span a 2", "a span 2", "auto 1", "1 auto",
             "span span", "a b", "1 2", "32768", "-32769", "span 65536", "32768 line", "span 65536 line",
             "SPAN 2", "Auto", "AUTO", "span 1e2", "1e2", "a-b", "-a", "span\x0c3", "  span 2  ", "", "span 2 ",
             "a 0", "0 a", "span 0 a", "span auto", "auto span", "10px", "a,", "span 2/* c */"]

REPCOUNT = ["1", "2", "0", "-1", "1.5", "65536", "auto-fit", "auto-fill", "AUTO-FIT", "auto", "1e2", "+3", " 3 ",
            "3 4", ""]

def main():
    rows = []
    enums = ["Display", "Position", "BoxSizing", "Overflow", "Direction", "Contain", "FlexWrap", "FlexDirection",
             "TextAlign", "Float", "Clear", "AlignItems", "AlignContent", "GridAutoFlow"]
    for t in enums:
        for k in KEYWORDS:
            for m in sorted(mutations(k)):
                rows.append((t, m))
        rows.append((t, ""))
        rows.append((t, "10px"))
    for t in ["LengthPercentage", "LengthPercentageAuto", "Dimension", "AvailableSpace",
              "MinTrackSizingFunction", "MaxTrackSizingFunction", "TrackSizingFunction", "GridTemplateComponent",
              "GridTemplateTracks", "GridTemplateComponents", "GridAutoTracks"]:
        for v in LENGTHS:
            rows.append((t, v))
        for k in ["auto", "AUTO", "min-content", "max-content", "fit-content", "stretch", "content", "none",
                  "fit-content(10px)", "fit-content(25%)", "fit-content(10PX)", "fit-content(auto)",
                  "fit-content(10px 20px)", "fit-content( 10px )", "calc(10px + 5%)", "10px 20px", " 10px ",
                  "10px/* c */", "/* c */10px", "", " ", "10 px", "10px)", "(10px)", "10px,"]:
            rows.append((t, k))
    for t in ["MinTrackSizingFunction", "MaxTrackSizingFunction", "TrackSizingFunction", "GridTemplateComponent",
              "GridTemplateTracks", "GridTemplateComponents", "GridAutoTracks"]:
        for v in TRACK_EXTRA + REPEAT + TEMPLATE:
            rows.append((t, v))
    for v in PLACEMENT:
        rows.append(("GridPlacement", v))
    for v in REPCOUNT:
        rows.append(("RepetitionCount", v))
    seen = set()
    with open("corpus.txt", "w") as f:
        f.write("# Generated by gen_corpus.py: Type<TAB>input\n")
        for t, v in rows:
            if "\n" in v or (t, v) in seen:
                continue
            seen.add((t, v))
            f.write(f"{t}\t{v}\n")
    print(len(seen))

main()
