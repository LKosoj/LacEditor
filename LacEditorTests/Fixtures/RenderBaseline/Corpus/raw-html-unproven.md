# Сырой HTML без доказательства блока

<script type="text/javascript">
// пример скрипта

document.getElementById("demo").innerHTML = "Привет";
</script>
после скрипта

<pre language="haskell"><code>
import Text.HTML.TagSoup

main :: IO ()
main = print $ parseTags tags
</code></pre>
после pre

<!-- комментарий
с пустой строкой

внутри -->
после комментария

<?php

  echo '>';

?>
после инструкции

<a  /><b2
data="foo" >

текст <!-- комментарий с --
дефисами - внутри --> конец
