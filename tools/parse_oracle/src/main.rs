use std::io::{self, BufRead, Write};
use std::str::FromStr;
use taffy::style::*;

fn emit<T: FromStr + serde::Serialize>(input: &str) -> String {
    match T::from_str(input) {
        Ok(value) => serde_json::to_string(&value).unwrap(),
        Err(_) => "ERR".to_string(),
    }
}

fn main() {
    let stdin = io::stdin();
    let mut out = io::BufWriter::new(io::stdout());
    for line in stdin.lock().lines() {
        let line = line.unwrap();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (ty, input) = line.split_once('\t').expect("Type<TAB>input");
        let result = match ty {
            "Display" => emit::<Display>(input),
            "Position" => emit::<Position>(input),
            "BoxSizing" => emit::<BoxSizing>(input),
            "Overflow" => emit::<Overflow>(input),
            "Direction" => emit::<Direction>(input),
            "Contain" => emit::<Contain>(input),
            "FlexWrap" => emit::<FlexWrap>(input),
            "FlexDirection" => emit::<FlexDirection>(input),
            "TextAlign" => emit::<TextAlign>(input),
            "Float" => emit::<Float>(input),
            "Clear" => emit::<Clear>(input),
            "AlignItems" => emit::<AlignItems>(input),
            "AlignContent" => emit::<AlignContent>(input),
            "LengthPercentage" => emit::<LengthPercentage>(input),
            "LengthPercentageAuto" => emit::<LengthPercentageAuto>(input),
            "Dimension" => emit::<Dimension>(input),
            "AvailableSpace" => emit::<AvailableSpace>(input),
            "GridAutoFlow" => emit::<GridAutoFlow>(input),
            "GridPlacement" => emit::<GridPlacement<String>>(input),
            "MinTrackSizingFunction" => emit::<MinTrackSizingFunction>(input),
            "MaxTrackSizingFunction" => emit::<MaxTrackSizingFunction>(input),
            "TrackSizingFunction" => emit::<TrackSizingFunction>(input),
            "RepetitionCount" => emit::<RepetitionCount>(input),
            "GridTemplateComponent" => emit::<GridTemplateComponent<String>>(input),
            "GridTemplateTracks" => emit::<GridTemplateTracks<String, TrackSizingFunction>>(input),
            "GridTemplateComponents" => emit::<GridTemplateTracks<String, GridTemplateComponent<String>>>(input),
            "GridAutoTracks" => match GridAutoTracks::from_str(input) {
                Ok(value) => serde_json::to_string(&value.0).unwrap(),
                Err(_) => "ERR".to_string(),
            },
            other => panic!("unknown type {other}"),
        };
        writeln!(out, "{ty}\t{input}\t{result}").unwrap();
    }
}
