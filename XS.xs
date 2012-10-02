#define PERL_NO_GET_CONTEXT     /* we want efficiency */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"
#include <stdio.h>
#include <string.h>


typedef struct tag_struct {
    char *name;
    int name_length;
    AV *perl_hash;
    HV *args;
    AV *modifiers;
    AV *child_nodes;
} tag_s;

typedef struct blocks_stack_struct {
    struct blocks_stack_struct *next;
    tag_s *tag;
    STRLEN inner_block_start;
} blocks_stack;

typedef struct tag_beginning_st {
    int tag_start;
    bool is_tag_end;
    int tag_name_start;
    int tag_name_end;
    int tag_name_len;
    char *name;
    char *lc_name;
} tag_beginning;

typedef struct Compiler_state {
    char *text;
    STRLEN length;
    int pos;
    int tag_start;
    int last_tag_ended;
    bool space_eater;
    HV *ids;
    HV *classes;
    HV *handlers;
    HV *modifiers;
    blocks_stack *blocks;
    AV *tokens;
    HV *template;
    HV *node_package;
    AV *error;
} compiler_s;

inline bool __is_whitespace(char ch) {
    return (ch==' ') || (ch=='\r') || (ch=='\f') || (ch=='\t') || (ch=='\n');
}

inline bool __is_word(char ch) {
    return ((ch>='a') && (ch<='z')) || ((ch>='A') && (ch<='Z')) || ((ch>='0') && (ch<='9')) || (ch=='_');
}

inline SV *utf8_on(SV *sv) {
    SvUTF8_on(sv);
    return sv;
}

// copy a lower-case version of the string into newly allocated buffer
char *str_cpylc(const char *str, STRLEN len) {
    char *buff = (char *)malloc(len+1);
    int ix;
    for (ix = 0; ix < len; ix++) {
        buff[ix] = tolower(str[ix]);
    }
    buff[ix] = '\0';
    return buff;
}

/* slurping an argument with paretensis. '', "", can have a tag inside */
SV *sfa_slurp_arg(pTHX_ compiler_s *cs) {
    int pos = cs->pos;
    char *text = cs->text;
    int length = cs->length;
    char enclosing = text[pos];
    pos++;
    int attr_start = pos;
    while ((pos < length) && (text[pos] != enclosing)) {
        if (text[pos] == '<') {
            // starting internal tag - scan to the end of it
            while ((pos < length) && (text[pos] != '>')) {
                pos++;
            }
        }
        else {
            pos++;
        }
    }
    if (pos >= length) { // text ended in the middle of a tag
        cs->pos = pos;
        return NULL;
    }
    SV *param = utf8_on(newSVpvn(cs->text + attr_start, pos-attr_start));
    pos++;
    cs->pos = pos;
    return param;
}

/* return 1 on success, 0 on tag end, -1 on error */
int scan_for_arg(pTHX_ compiler_s *cs, tag_s *tag) {
    int pos = cs->pos;
    char *text = cs->text;
    int length = cs->length;
    while ((pos < length) && (__is_whitespace(text[pos]))) {
        pos++;
    }
    if ((pos >= length) || ( (text[pos]!=':') && !__is_word(text[pos]) )) {
        cs->pos = pos;
        return 0;
    }
    int name_start = pos;
    while ((pos < length) && ( (text[pos]==':') || __is_word(text[pos]) )) {
        pos++;
    }
    int name_end = pos;
    int name_len = name_end - name_start;
    while ((pos < length) && (__is_whitespace(text[pos]))) {
        pos++;
    }
    if (text[pos] != '=') {
        /* arg without a '=' - this is a name arg */
        hv_stores(tag->args, "name", newSVpvn(text+name_start, name_len));
        cs->pos = pos;
        return 1;
    }
    pos++; /* passing the '=' */
    while ((pos < length) && (__is_whitespace(text[pos]))) {
        pos++;
    }
    if ((text[pos] != '\'') && (text[pos] != '"')) {
        /* bare argument - can not have multiple arguments */
        int arg_start = pos;
        while (!__is_whitespace(text[pos]) && (text[pos] != '$') && (text[pos] != '>')) {
            pos++;
        }
        if (pos==arg_start) {
            av_push(cs->error, newSViv(name_start));
            av_push(cs->error, newSVpv("Attribute [_1] ended without value at line #" ,0));
            av_push(cs->error, newSVpvn(text+name_start, name_len));
            return -1;
        }
        char *low_name = str_cpylc(text+name_start, name_len);
        hv_store(tag->args, low_name, name_len, utf8_on(newSVpvn(text+arg_start, pos-arg_start)), 0);
        cs->pos = pos;
        free(low_name);
        return 1;
    }
    cs->pos = pos;
    SV *arg = sfa_slurp_arg(aTHX_ cs);
    if (arg==NULL) {
        av_push(cs->error, newSViv(name_start));
        av_push(cs->error, newSVpv("Failed while parsing values for Attribute [_1] at line #" ,0));
        av_push(cs->error, newSVpvn(text+name_start, name_len));
        return -1;
    }
    if ((text[cs->pos]==',') && ((text[cs->pos+1] == '\'') || (text[cs->pos+1] == '"'))) {
        AV *args = newAV();
        av_push(args, arg);
        while ((text[cs->pos]==',') && ((text[cs->pos+1] == '\'') || (text[cs->pos+1] == '"'))) {
            cs->pos++;
            arg = sfa_slurp_arg(aTHX_ cs);
            if (arg==NULL) {
                av_push(cs->error, newSViv(name_start));
                av_push(cs->error, newSVpv("Failed while parsing values for Attribute [_1] at line #" ,0));
                av_push(cs->error, newSVpvn(text+name_start, name_len));
                SvREFCNT_dec(args);
                return -1;
            }
            av_push(args, arg);
        }
        arg = newRV_noinc((SV*)args);
    }
    char *low_name = str_cpylc(text+name_start, name_len);
    hv_store(tag->args, low_name, name_len, arg, 0);

    if ((name_len ==2) && (0 == strncmp("id", low_name, 2))) {
        hv_store_ent(cs->ids, arg, newRV_inc((SV*)tag->perl_hash), 0);
    }
    if ((name_len ==5) && (0 == strncmp("class", low_name, 5))) {
        STRLEN arg_len;
        char *arg_str = SvPV(arg, arg_len);
        char *low_str = str_cpylc(arg_str, arg_len);
        AV *ar_class;
        SV **ar_ref = hv_fetch(cs->classes, low_str, arg_len, 0);
        if (ar_ref == NULL) {
            ar_class = newAV();
            hv_store(cs->classes, low_str, arg_len, newRV_noinc((SV*)ar_class), 0);
        }
        else {
            ar_class = (AV *)SvRV(*ar_ref);
        }
        av_push(ar_class, newRV_inc((SV*)tag->perl_hash));
        free(low_str);
    }
    if (hv_exists(cs->modifiers, low_name, name_len)) {
        AV *ar_args = newAV();
        av_push(ar_args, newSVpvn(low_name, name_len));
        SvREFCNT_inc(arg);
        av_push(ar_args, arg);
        av_push(tag->modifiers, newRV_noinc((SV*)ar_args));        
    }
    free(low_name);
    return 1;
}

void add_tag_parents(pTHX_ compiler_s *cs, AV *p_tag, bool is_text) {
    if (cs->blocks == NULL) {
        av_push(cs->tokens, sv_bless(newRV_noinc((SV*)p_tag), cs->node_package));
        av_push(p_tag, (((cs->template == NULL) || is_text) ? &PL_sv_undef : sv_rvweaken(newRV_inc((SV*)cs->template))));
    }
    else {
        tag_s *parent = cs->blocks->tag;
        if (parent->child_nodes == NULL) {
            AV *children = newAV();
            parent->child_nodes = children;
            av_store(parent->perl_hash, 2, newRV_noinc((SV*)children));
        }
        av_push(parent->child_nodes, sv_bless(newRV_noinc((SV*)p_tag), cs->node_package));
        av_push(p_tag, (is_text ? &PL_sv_undef : sv_rvweaken(newRV_inc((SV*)parent->perl_hash))));
    }
    av_push(p_tag, ((cs->template == NULL) ? &PL_sv_undef : sv_rvweaken(newRV_inc((SV*)cs->template))));
}

void create_text_tag(pTHX_ compiler_s *cs, int end) {
    int start = cs->last_tag_ended;
    if (start == end) {
        return;
    }
    if (cs->space_eater) {
        while ((start < end) && __is_whitespace(cs->text[start])) {
            start++;
        }
    }
    if (start==end) {
        return;
    }
    AV *p_tag = newAV();
    av_push(p_tag, newSVpv("TEXT", 0));
    av_push(p_tag, utf8_on(newSVpvn(cs->text + start, end-start)));
    av_push(p_tag, &PL_sv_undef);
    av_push(p_tag, &PL_sv_undef);
    av_push(p_tag, &PL_sv_undef);
    add_tag_parents(aTHX_ cs, p_tag, true);
}

// returns 1 if tag beginning found, otherwise 0
// if successful, tag_begin->lc_name will contain allocated memory
int detect_tag_beginning(compiler_s *cs, tag_beginning *tag_begin) {
    int pos = cs->pos;
    char *text = cs->text;
    int length = cs->length;
    while ((pos < length) && (text[pos] != '<')) {
        pos++;
    }
    if (pos==length) {
        cs->pos = pos;
        return 0;
    }
    tag_begin->tag_start = pos;
    pos++;
    tag_begin->is_tag_end = false;
    if (text[pos] == '/') {
        tag_begin->is_tag_end = true;
        pos++;
    }
    else if (text[pos] == '$') { 
        pos++;
    }
    if (((text[pos] != 'm') && (text[pos] != 'M')) || ((text[pos+1] != 't') && (text[pos+1] != 'T'))) {
        /* not an MT tag, skip */
        cs->pos = pos;
        return 0;
    }
    pos += 2;
    if (text[pos] == ':')
        pos++;
    tag_begin->tag_name_start = pos;
    tag_begin->name = text + tag_begin->tag_name_start;
    while ((pos < length) && (__is_word(text[pos]) || (text[pos]==':'))) {
        pos++;
    }
    cs->pos = pos;
    if (pos == tag_begin->tag_name_start) {
        return 0;
    }
    tag_begin->tag_name_end = pos;
    tag_begin->tag_name_len = tag_begin->tag_name_end-tag_begin->tag_name_start;
    tag_begin->lc_name = str_cpylc(tag_begin->name, tag_begin->tag_name_len);
    return 1;
}

int process_ignore_tag(compiler_s *cs) {
    char *text = cs->text;
    int length = cs->length;
    tag_beginning tag_ignore;
    int depth = 1;
    while (cs->pos < length) {
        if (detect_tag_beginning(cs, &tag_ignore) == 0) {
            continue;
        }
        if ((tag_ignore.tag_name_len != 6) || (0 != strncmp(tag_ignore.lc_name, "ignore", 6))) {
            // this is not an ignore tag - skip
            free(tag_ignore.lc_name);
            continue;
        }
        free(tag_ignore.lc_name);
        while ((cs->pos < length) && (__is_whitespace(text[cs->pos]))) {
            cs->pos++;
        }
        if (cs->pos >= length) {
            break;
        }
        if (text[cs->pos]!='>') {
            // problem with this tag, but we are in ignore block, so we continue to parse
            continue;
        }
        cs->pos++;
        depth += (tag_ignore.is_tag_end ? -1 : 1);
        if (depth < 1) {
            break;
        }
    }
    if (depth >= 1) {
        return -1;
    }
    return 0;
}

int process_block_endtag(pTHX_ compiler_s *cs, tag_beginning *tag_begin) {
    /* scan to the end of the end tag, and close block tag */
    int pos = cs->pos;
    char *text = cs->text;
    int length = cs->length;

    while ((pos < length) && __is_whitespace(text[pos])) {
        pos++;
    }
    if ((pos >= length) || (text[pos]!='>')) {
        // TODO: hmmm.. problem with the tag
        av_push(cs->error, newSViv(tag_begin->tag_start));
        av_push(cs->error, newSVpv("Failed while parsing tag [_1] at line #" ,0));
        av_push(cs->error, newSVpvn(tag_begin->lc_name, tag_begin->tag_name_len));
        return -1;
    }
    pos++;
    cs->last_tag_ended = cs->pos = pos;

    blocks_stack *head = cs->blocks;
    while (head != NULL) {
        if ((head->tag->name_length == tag_begin->tag_name_len) && (0==strncmp(head->tag->name, tag_begin->lc_name, tag_begin->tag_name_len))) {
            cs->blocks = head->next;
            tag_s *parent = head->tag;
            av_store(parent->perl_hash, 3, utf8_on(newSVpvn(text+head->inner_block_start, tag_begin->tag_start-head->inner_block_start)));
            free(parent->name);
            free(parent);
            free(head);
            break;
        }
        if (((head->tag->name_length == 4) && (0==strncmp(head->tag->name, "else", 4))) 
            || ((head->tag->name_length == 6) && (0==strncmp(head->tag->name, "elseif", 6)))) {
            // unclosed else/elseif tags
            cs->blocks = head->next;
            tag_s *parent = head->tag;
            av_store(parent->perl_hash, 3, utf8_on(newSVpvn(text+head->inner_block_start, tag_begin->tag_start-head->inner_block_start)));
            free(parent->name);
            free(parent);
            free(head);
            head = cs->blocks;
            continue;
        }
        av_push(cs->error, newSViv(tag_begin->tag_start));
        av_push(cs->error, newSVpv("Found mismatched closing tag [_1] at line #" ,0));
        av_push(cs->error, newSVpvn(tag_begin->lc_name, tag_begin->tag_name_len));
        return -1;
    } 
    return 0;
}

// returns
// 0 for normal ending (either found or have a tag)
// -1 for error (corrupted tag)
int scan_for_tag(pTHX_ compiler_s *cs) {
    tag_beginning tag_begin;
    if (detect_tag_beginning(cs, &tag_begin) == 0) {
        return 0;
    }

    create_text_tag(aTHX_ cs, tag_begin.tag_start);
    if (tag_begin.is_tag_end) {
        int ret = process_block_endtag(aTHX_ cs, &tag_begin);
        free(tag_begin.lc_name);
        return ret;
    }

    if (!hv_exists(cs->handlers, tag_begin.lc_name, tag_begin.tag_name_len)) {
        av_push(cs->error, newSViv(tag_begin.tag_start));
        av_push(cs->error, newSVpv("Undefined tag [_1] at line #" ,0));
        av_push(cs->error, newSVpvn(tag_begin.lc_name, tag_begin.tag_name_len));
        free(tag_begin.lc_name);
        return -1;
    }

    tag_s *tag = (tag_s*)malloc(sizeof(tag_s));
    tag->name = tag_begin.lc_name;
    tag->name_length = tag_begin.tag_name_len;
    tag->perl_hash = newAV();
    tag->args = newHV();
    tag->modifiers = newAV();
    tag->child_nodes = NULL;
    AV *p_tag = tag->perl_hash;
    av_push(p_tag, newSVpvn(tag_begin.name, tag_begin.tag_name_len));
    av_push(p_tag, newRV_noinc((SV*)tag->args));
    av_push(p_tag, &PL_sv_undef); // child nodes - start with an undef
    av_push(p_tag, &PL_sv_undef); // node value - to be filled for block tags on close
    av_push(p_tag, newRV_noinc((SV*)tag->modifiers));
    add_tag_parents(aTHX_ cs, p_tag, false);

    while (1) {
        int res = scan_for_arg(aTHX_ cs, tag);
        if (res == 0)
            break;
        if (res == -1) {
            free(tag->name);
            free(tag);
            return -1;
        }
    }

    int pos = cs->pos;
    char *text = cs->text;
    int length = cs->length;
    if ((pos < length) && (text[pos]=='-')) {
        cs->space_eater = true;
        pos++;
    }
    else {
        cs->space_eater = false;
    }
    if ((pos < length) && ((text[pos]=='$') || (text[pos]=='/'))) {
        pos++;
    }
    if ((pos >= length) || (text[pos]!='>')) {
        // TODO: hmmm.. problem with the tag
        av_push(cs->error, newSViv(tag_begin.tag_start));
        av_push(cs->error, newSVpv("Failed while parsing tag [_1] at line #" ,0));
        av_push(cs->error, newSVpvn(tag_begin.lc_name, tag_begin.tag_name_len));
        free(tag->name);
        free(tag);
        return -1;
    }
    pos++;
    cs->last_tag_ended = cs->pos = pos;

    if ((tag_begin.tag_name_len == 6) && (0==strncmp(tag_begin.lc_name, "ignore", 6))) {
        int ret = process_ignore_tag(cs);
        if (ret == 0) {
            av_store(tag->perl_hash, 2, newRV_noinc((SV*)newAV()));
            av_store(tag->perl_hash, 3, newSVpvn("", 0));
            cs->last_tag_ended = cs->pos;
        }
        else {
            av_push(cs->error, newSViv(tag_begin.tag_start));
            av_push(cs->error, newSVpv("Failed while parsing tag [_1] at line #" ,0));
            av_push(cs->error, newSVpvn(tag_begin.lc_name, tag_begin.tag_name_len));
        }
        free(tag->name);
        free(tag);
        return ret;
    }
    SV **hnlr = hv_fetch(cs->handlers, tag_begin.lc_name, tag_begin.tag_name_len, 0);
    AV *hndr_ar = (AV*)(SvRV(*hnlr));
    SV **hdlr_type = av_fetch(hndr_ar, 1, 0);
    int type = SvIV(*hdlr_type);
    if (type != 0) {
        // block/conditional tag
        blocks_stack *head = (blocks_stack *)malloc(sizeof(blocks_stack));
        head->tag = tag;
        head->next = cs->blocks;
        head->inner_block_start = pos;
        cs->blocks = head;
    }
    else {
        free(tag->name);
        free(tag);
    }
    return 0;
}

MODULE = MT::Builder::XS       PACKAGE = MT::Builder::XS      
PROTOTYPES: ENABLE

SV*
compiler(handlers, modifiers, ids, classes, error, text, template)
    SV *handlers;
    SV *modifiers;
    SV *ids;
    SV *classes;
    SV *error;
    SV *text;
    SV *template;
    CODE:
        compiler_s cs;
        cs.text = SvPV(text, cs.length);
        cs.pos = 0;
        cs.tag_start = 0;
        cs.last_tag_ended = 0;
        cs.ids = (HV*)SvRV(ids);
        cs.classes = (HV*)SvRV(classes);
        cs.modifiers = (HV*)SvRV(modifiers);
        cs.handlers = (HV*)SvRV(handlers);
        cs.error = (AV*)SvRV(error);
        cs.blocks = NULL;
        cs.tokens = newAV();
        cs.space_eater = false;
        if (SvOK(template)) {
            cs.template = (HV*)SvRV(template);
        }
        else {
            cs.template = NULL;
        }
        cs.node_package = gv_stashpvn("MT::Template::Node", 18, 0);
        bool no_error = true;
        while (cs.pos < cs.length) {
            int ret = scan_for_tag(aTHX_ &cs);
            if (ret == -1) {
                no_error = false;
                break;
            }
        }
        if (cs.blocks != NULL) {
            blocks_stack *head = cs.blocks;
            if (no_error) {
                av_push(cs.error, newSViv(head->inner_block_start));
                av_push(cs.error, newSVpv("Tag [_1] left unclosed at line #" ,0));
                av_push(cs.error, newSVpvn(head->tag->name, head->tag->name_length));
                no_error = false;
            }
            while (head != NULL) {
                cs.blocks = head->next;
                free(head->tag->name);
                free(head->tag);
                free(head);
                head = cs.blocks;
            }
        }
        if (no_error) {
            create_text_tag(aTHX_ &cs, cs.length);
            RETVAL = newRV_noinc((SV*)(cs.tokens));
        }
        else {
            SvREFCNT_dec(cs.tokens);
            RETVAL = &PL_sv_undef;
        }
    OUTPUT:
        RETVAL

