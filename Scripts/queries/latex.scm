; BareLipi's LaTeX highlights (tree-sitter-latex ships none). MIT, as the rest
; of BareLipi.

[(line_comment) (block_comment) (comment_environment)] @comment

(command_name) @function
(todo_command_name) @function

(begin command: _ @keyword)
(end command: _ @keyword)
(begin name: (curly_group_text (text) @type))
(end name: (curly_group_text (text) @type))

[(section) (subsection) (subsubsection) (chapter) (part) (paragraph) (subparagraph)] @keyword

[(inline_formula) (displayed_equation) (math_environment)] @string

(label_definition name: (curly_group_label (label) @constant))
(label_reference names: (curly_group_label_list (label) @constant))
(citation keys: (curly_group_text_list (text) @constant))

[(package_include) (class_include)] @keyword
(new_command_definition declaration: (curly_group_command_name (command_name) @function))

(key_value_pair key: (text) @property)
(uri) @string
(path) @string

[(subscript) (superscript)] @operator
(placeholder) @variable
