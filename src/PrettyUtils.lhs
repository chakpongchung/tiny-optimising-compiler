\begin{code}
module PrettyUtils where
import Data.Text.Prettyprint.Doc.Render.Text
import Data.Text.Prettyprint.Doc
import qualified Data.Text.Lazy as L
docToText :: Doc ann -> L.Text
docToText doc = renderLazy (layoutPretty defaultLayoutOptions doc)

docToString :: Doc ann -> String
docToString = L.unpack . docToText

prettyableToText :: Pretty a => a -> L.Text
prettyableToText a = docToText (pretty a)

prettyableToString :: Pretty a => a -> String
prettyableToString  a = docToString (pretty a)
\end{code}
