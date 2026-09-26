#define TS_XML
// Inlined from the grammar repo's common/scanner.h.
#pragma once

#include "tree_sitter/parser.h"
#include <wctype.h>

enum TokenType {
    PI_TARGET,
    PI_CONTENT,
    COMMENT,

#ifdef TS_XML
    CHAR_DATA,
    CDATA,
    XML_MODEL,
    XML_STYLESHEET,
    START_TAG_NAME,
    END_TAG_NAME,
    ERRONEOUS_END_NAME,
    SELF_CLOSING_TAG_DELIMITER,
#endif
};

/// Advance the lexer if the next token matches the given character
#define advance_if_eq(lexer, chr) \
    if (!lexer->eof(lexer) && (lexer)->lookahead == (chr)) advance((lexer)); else return false

#ifdef _WIN32
#undef max
#undef min
#endif

/// Advance the lexer to the next token
static inline void advance(TSLexer *lexer) { lexer->advance(lexer, false); }

/// Check if the character is valid in a name
/// TODO: explicitly follow https://www.w3.org/TR/xml11/#NT-Name
static inline bool is_valid_name_char(wchar_t chr) {
    return iswalnum(chr) || chr == '_' || chr == ':' || chr == '.' || chr == '-' || chr == 0xB7;
}

/// Check if the character is valid to start a name
/// TODO: explicitly follow https://www.w3.org/TR/xml11/#NT-NameStartChar
static inline bool is_valid_name_start_char(wchar_t chr) {
    return iswalpha(chr) || chr == '_' || chr == ':';
}

/// Check if the lexer matches the given word
static inline bool check_word(TSLexer *lexer, const char *const word, unsigned length) {
    for (unsigned j = 0; j < length; ++j) {
        advance_if_eq(lexer, word[j]);
    }
    return true;
}

/// Scan for the target of a PI node
static bool scan_pi_target(TSLexer *lexer, const bool *valid_symbols) {
    bool advanced_once = false, found_x_first = false;
#ifndef TS_XML
    (void)valid_symbols;
#endif

    if (is_valid_name_start_char(lexer->lookahead)) {
        if (lexer->lookahead == 'x' || lexer->lookahead == 'X') {
            found_x_first = true;
            lexer->mark_end(lexer);
        }
        advanced_once = true;
        advance(lexer);
    }

    if (advanced_once) {
        while (is_valid_name_char(lexer->lookahead)) {
            if (found_x_first && (lexer->lookahead == 'm' || lexer->lookahead == 'M')) {
                advance(lexer);
                if (lexer->lookahead == 'l' || lexer->lookahead == 'L') {
                    advance(lexer);
                    if (is_valid_name_char(lexer->lookahead)) {
#ifdef TS_XML
                        found_x_first = false;
                        bool last_char_hyphen = lexer->lookahead == '-';
                        advance(lexer);
                        if (last_char_hyphen) {
                            if (valid_symbols[XML_MODEL] && check_word(lexer, "model", 5))
                                return false;
                            if (valid_symbols[XML_STYLESHEET] && check_word(lexer, "stylesheet", 10))
                                return false;
                        }
#endif
                    } else {
                        return false;
                    }
                }
            }

            found_x_first = false;
            advance(lexer);
        }

        lexer->mark_end(lexer);
        lexer->result_symbol = PI_TARGET;
        return true;
    }

    return false;
}

/// Scan for the content of a PI node
static bool scan_pi_content(TSLexer *lexer) {
    while (!lexer->eof(lexer) && lexer->lookahead != '\n' && lexer->lookahead != '?')
        advance(lexer);

    if (lexer->lookahead != '?')
        return false;

    lexer->mark_end(lexer);
    advance(lexer);

    if (lexer->lookahead == '>') {
        advance(lexer);
        while (lexer->lookahead == ' ')
            advance(lexer);
        advance_if_eq(lexer, '\n');
        lexer->result_symbol = PI_CONTENT;
        return true;
    }

    return false;
}

/// Scan for a Comment node
static bool scan_comment(TSLexer *lexer) {
    advance_if_eq(lexer, '-');
    advance_if_eq(lexer, '-');

    while (!lexer->eof(lexer)) {
        if (lexer->lookahead == '-') {
            advance(lexer);
            if (lexer->lookahead == '-') {
                advance(lexer);
                break;
            }
        } else {
            advance(lexer);
        }
    }

    if (lexer->lookahead == '>') {
        advance(lexer);
        lexer->mark_end(lexer);
        lexer->result_symbol = COMMENT;
        return true;
    }

    return false;
}

#include "tree_sitter/array.h"

#include <string.h>

typedef Array(char) String;

typedef Array(String) Vector;

static inline bool string_eq(String *a, String *b) {
    if (a->size != b->size) {
        return false;
    }
    return memcmp(a->contents, b->contents, a->size) == 0;
}

static String scan_tag_name(TSLexer *lexer) {
    String tag_name = array_new();
    if (is_valid_name_start_char(lexer->lookahead)) {
        array_push(&tag_name, (char)lexer->lookahead);
        advance(lexer);
    }
    while (is_valid_name_char(lexer->lookahead)) {
        array_push(&tag_name, (char)lexer->lookahead);
        advance(lexer);
    }
    return tag_name;
}

static bool scan_start_tag_name(Vector *tags, TSLexer *lexer) {
    String tag_name = scan_tag_name(lexer);
    if (tag_name.size == 0) {
        array_delete(&tag_name);
        return false;
    }

    lexer->result_symbol = START_TAG_NAME;
    array_push(tags, tag_name);
    return true;
}

static bool scan_end_tag_name(Vector *tags, TSLexer *lexer) {
    String tag_name = scan_tag_name(lexer);
    if (tag_name.size == 0) {
        array_delete(&tag_name);
        return false;
    }

    if (tags->size > 0 && string_eq(array_back(tags), &tag_name)) {
        String last_tag = array_pop(tags);
        array_delete(&last_tag);
        lexer->result_symbol = END_TAG_NAME;
    } else {
        lexer->result_symbol = ERRONEOUS_END_NAME;
    }
    array_delete(&tag_name);
    return lexer->result_symbol == END_TAG_NAME;
}

static bool scan_self_closing_tag_delimiter(Vector *tags, TSLexer *lexer) {
    advance(lexer);
    advance_if_eq(lexer, '>');
    if (tags->size > 0) {
        String last_tag = array_pop(tags);
        array_delete(&last_tag);
        lexer->result_symbol = SELF_CLOSING_TAG_DELIMITER;
    }
    return true;
}

/// Check if the lexer is in error recovery mode
static inline bool in_error_recovery(const bool *valid_symbols) {
    return valid_symbols[PI_TARGET] && valid_symbols[PI_CONTENT] && valid_symbols[COMMENT] &&
           valid_symbols[CHAR_DATA] && valid_symbols[CDATA];
}

/// Check if the lexer is in a char data node
static inline bool in_char_data(TSLexer *lexer) {
    return !lexer->eof(lexer) && lexer->lookahead != '<' && lexer->lookahead != '&';
}

/// Scan for a CharData node
static bool scan_char_data(TSLexer *lexer) {
    bool advanced_once = false;

    while (in_char_data(lexer)) {
        if (lexer->lookahead == ']') {
            lexer->mark_end(lexer);
            advance(lexer);
            if (lexer->lookahead == ']') {
                advance(lexer);
                if (lexer->lookahead == '>') {
                    advance(lexer);
                    if (advanced_once) {
                        lexer->result_symbol = CHAR_DATA;
                        return false;
                    }
                }
            }
        }
        advanced_once = true;
        if (in_char_data(lexer)) {
            advance(lexer);
        }
    }

    if (advanced_once) {
        lexer->mark_end(lexer);
        lexer->result_symbol = CHAR_DATA;
        return true;
    }
    return false;
}

/// Scan for a CData node
static bool scan_cdata(TSLexer *lexer) {
    bool advanced_once = false;

    while (!lexer->eof(lexer)) {
        if (lexer->lookahead == ']') {
            lexer->mark_end(lexer);
            advance(lexer);
            if (lexer->lookahead == ']') {
                advance(lexer);
                if (lexer->lookahead == '>' && advanced_once) {
                    lexer->result_symbol = CDATA;
                    return true;
                }
            }
        }
        advanced_once = true;
        advance(lexer);
    }

    return false;
}

bool tree_sitter_xml_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid_symbols) {
    Vector *tags = (Vector *)payload;

    if (in_error_recovery(valid_symbols)) {
        return false;
    }

    if (valid_symbols[PI_TARGET]) {
        return scan_pi_target(lexer, valid_symbols);
    }

    if (valid_symbols[PI_CONTENT]) {
        return scan_pi_content(lexer);
    }

    if (valid_symbols[CHAR_DATA] && scan_char_data(lexer)) {
        return true;
    }

    if (valid_symbols[CDATA] && scan_cdata(lexer)) {
        return true;
    }

    switch (lexer->lookahead) {
        case '<':
            lexer->mark_end(lexer);
            advance(lexer);
            if (lexer->lookahead == '!') {
                advance(lexer);
                return scan_comment(lexer);
            }
            break;
        case '/':
            if (valid_symbols[SELF_CLOSING_TAG_DELIMITER]) {
                return scan_self_closing_tag_delimiter(tags, lexer);
            }
            break;
        case '\0':
            break;
        default:
            if (valid_symbols[START_TAG_NAME]) {
                return scan_start_tag_name(tags, lexer);
            }
            if (valid_symbols[END_TAG_NAME]) {
                return scan_end_tag_name(tags, lexer);
            }
    }

    return false;
}

void *tree_sitter_xml_external_scanner_create() {
    Vector *tags = (Vector *)ts_calloc(1, sizeof(Vector));
    if (tags == NULL) abort();
    array_init(tags);
    return tags;
}

void tree_sitter_xml_external_scanner_destroy(void *payload) {
    Vector *tags = (Vector *)payload;
    for (uint32_t i = 0; i < tags->size; ++i) {
        array_delete(array_get(tags, i));
    }
    array_delete(tags);
    ts_free(tags);
}

unsigned tree_sitter_xml_external_scanner_serialize(void *payload, char *buffer) {
    Vector *tags = (Vector *)payload;
    uint32_t tag_count = tags->size > UINT16_MAX ? UINT16_MAX : tags->size;
    uint32_t serialized_tag_count = 0, size = sizeof tag_count;

    memcpy(&buffer[size], &tag_count, size);
    size += sizeof tag_count;

    for (; serialized_tag_count < tag_count; ++serialized_tag_count) {
        String *tag = array_get(tags, serialized_tag_count);
        uint32_t name_length = tag->size;
        if (name_length > UINT8_MAX) {
            name_length = UINT8_MAX;
        }
        if (size + 2 + name_length >= TREE_SITTER_SERIALIZATION_BUFFER_SIZE) {
            break;
        }
        buffer[size++] = (char)name_length;
        if (name_length > 0) {
            memcpy(&buffer[size], tag->contents, name_length);
        }
        array_delete(tag);
        size += name_length;
    }

    memcpy(&buffer[0], &serialized_tag_count, sizeof serialized_tag_count);
    return size;
}

void tree_sitter_xml_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
    Vector *tags = (Vector *)payload;

    for (unsigned i = 0; i < tags->size; ++i) {
        array_delete(array_get(tags, i));
    }
    array_clear(tags);

    if (length == 0) return;

    uint32_t size = 0, tag_count = 0, serialized_tag_count = 0;
    memcpy(&serialized_tag_count, &buffer[size], sizeof serialized_tag_count);
    size += sizeof serialized_tag_count;
    memcpy(&tag_count, &buffer[size], sizeof tag_count);
    size += sizeof tag_count;

    if (tag_count == 0) return;

    array_reserve(tags, tag_count);

    uint32_t iter = 0;
    for (; iter < serialized_tag_count; ++iter) {
        String tag = array_new();
        tag.size = (uint8_t)buffer[size++];
        if (tag.size > 0) {
            array_reserve(&tag, tag.size + 1);
            memcpy(tag.contents, &buffer[size], tag.size);
            size += tag.size;
        }
        array_push(tags, tag);
    }
    // add zero tags if we didn't read enough, this is because the
    // buffer had no more room but we held more tags.
    for (; iter < tag_count; ++iter) {
        String tag = array_new();
        array_push(tags, tag);
    }
}
