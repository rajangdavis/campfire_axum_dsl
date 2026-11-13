# Random HTML-ish bodies for action_text_html vs Rails' ActionText::Content (one JSON string per line).
import json, random, sys
random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
atoms = ["<b>", "</b>", "<i>", "</i>", "<div>", "</div>", "<p>", "</p>", "<br>", "<br/>", "<ul><li>", "</li>", "</ul>",
         "&", "&amp;", "&nbsp;", "&lt;", "<", ">", "\"", "'", "\r\n", "\n", "\r", "\t", " ", "  ", "\x00", "é", "😀",
         "<a href=\"x?a=1&b=2\">", "</a>", "<img src=x>", "<table><tr><td>", "</td>", "<!-- c -->", "<script>x</script>",
         "<action-text-attachment sgid=\"s\" content-type=\"application/vnd.campfire.mention\"></action-text-attachment>",
         "<span title='a\"b'>", "</span>", "<pre>", "</pre>", "<textarea>", "</textarea>", "<html>", "<body>", "<head>",
         "word", "line one", "Hello", "@Bender", "x", " ", "<foo bar>", "</p></p>", "<option>", "<select>"]
for _ in range(int(sys.argv[2]) if len(sys.argv) > 2 else 600):
    print(json.dumps("".join(random.choice(atoms) for _ in range(random.randint(0, 12)))))
