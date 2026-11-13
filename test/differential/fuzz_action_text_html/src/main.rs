// action_text_html as axum_dsl emits it (sanitize.rb ACTION_TEXT_HTML_CALL), over JSON-string lines on stdin.
use std::io::BufRead;
fn axum_dsl_action_text_html(html: &str) -> String {
    let stripped = html.trim_matches(|c: char| matches!(c, '\0' | ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r'));
    ::scraper::Html::parse_fragment(stripped).root_element().inner_html()
}

fn main() {
    for line in std::io::stdin().lock().lines() {
        let input: String = serde_json::from_str(&line.unwrap()).unwrap();
        println!("{}", serde_json::to_string(&axum_dsl_action_text_html(&input)).unwrap());
    }
}
