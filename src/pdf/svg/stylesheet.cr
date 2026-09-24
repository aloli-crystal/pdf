require "xml"

module PDF
  module SVG
    # Feuille de style CSS d'un document SVG : les règles des éléments
    # `<style>`, appliquées aux éléments par `Renderer#get_style`.
    #
    # Seuls les sélecteurs simples sont gérés : type (`text`), classe
    # (`.cote`), id (`#x`), universel (`*`), leurs combinaisons sans
    # espace (`text.cote`) et les listes (`a, b`). Un sélecteur avec
    # combinateur, attribut ou pseudo-classe est ignoré, ainsi que les
    # règles `@media`, `@font-face`, `@import`…
    class Stylesheet
      # Sélecteur composé simple : type ou `*` (nil), classes, id.
      record Selector, tag : String?, classes : Array(String), id : String? do
        # Spécificité CSS : (ids, classes, types).
        def specificity : Tuple(Int32, Int32, Int32)
          {id ? 1 : 0, classes.size, tag ? 1 : 0}
        end

        def matches?(node : XML::Node) : Bool
          return false if (t = tag) && node.name != t
          return false if (i = id) && node["id"]? != i
          return true if classes.empty?
          node_classes = node["class"]?.try(&.split) || [] of String
          classes.all? { |c| node_classes.includes?(c) }
        end
      end

      # Une déclaration `propriété: valeur`, marquée `!important` ou non.
      record Declaration, property : String, value : String, important : Bool

      record Rule, selector : Selector, order : Int32, declarations : Array(Declaration)

      SELECTOR_RE = /\A(\*|[A-Za-z][\w-]*)?((?:[.#][A-Za-z_-][\w-]*)*)\z/

      getter rules = [] of Rule

      # Déclarations retenues pour chaque élément, indexées par l'adresse
      # du nœud libxml (stable tant que le document est vivant).
      @cache = {} of UInt64 => Hash(String, Declaration)

      def initialize(css : String = "")
        add(css)
      end

      # Ajoute le contenu d'un élément `<style>` ; l'ordre des appels est
      # l'ordre du source, qui départage deux règles de même spécificité.
      def add(css : String) : Nil
        css = css.gsub(%r{/\*.*?\*/}m, "")
        pos = 0
        while open = css.index('{', pos)
          prelude = css[pos...open]
          # Une instruction sans bloc (`@import …;`) précède la règle.
          prelude = prelude[(prelude.rindex(';') || -1) + 1..].strip
          close = matching_brace(css, open)
          body = css[open + 1...close]
          add_rule(prelude, body) unless prelude.starts_with?('@')
          pos = close + 1
        end
        @cache.clear
      end

      def empty? : Bool
        @rules.empty?
      end

      # Déclarations applicables à `node`, par propriété : la règle la
      # plus spécifique l'emporte, puis la dernière du source.
      def declarations_for(node : XML::Node) : Hash(String, Declaration)
        @cache[node.to_unsafe.address] ||= compute(node)
      end

      # Valeur CSS de `property` pour `node`, ou nil.
      def lookup(node : XML::Node, property : String) : Declaration?
        return nil if @rules.empty?
        declarations_for(node)[property]?
      end

      # Découpe `prop: valeur; …` (contenu d'une règle ou d'un attribut
      # `style`) en déclarations. La valeur s'arrête au premier `;`
      # et peut contenir `:` (`url(http://…)`).
      def self.parse_declarations(text : String) : Array(Declaration)
        text.split(';').compact_map do |declaration|
          colon = declaration.index(':')
          next unless colon
          property = declaration[0...colon].strip.downcase
          value = declaration[colon + 1..].strip
          important = false
          if value =~ /\s*!\s*important\z/i
            value = $~.pre_match.strip
            important = true
          end
          next if property.empty? || value.empty?
          Declaration.new(property, value, important)
        end
      end

      # Sélecteur simple, ou nil s'il n'est pas géré.
      def self.parse_selector(text : String) : Selector?
        m = SELECTOR_RE.match(text)
        return nil unless m
        tag = m[1]?
        tag = nil if tag == "*"
        suffix = m[2]
        return nil if tag.nil? && suffix.empty? && text != "*"
        classes = [] of String
        id = nil
        suffix.scan(/([.#])([\w-]+)/) do |part|
          if part[1] == "."
            classes << part[2]
          else
            id = part[2]
          end
        end
        Selector.new(tag, classes, id)
      end

      private def add_rule(prelude : String, body : String) : Nil
        declarations = Stylesheet.parse_declarations(body)
        return if declarations.empty?
        prelude.split(',').each do |text|
          if selector = Stylesheet.parse_selector(text.strip)
            @rules << Rule.new(selector, @rules.size, declarations)
          end
        end
      end

      # Position de l'accolade fermante qui répond à celle en `open`
      # (les blocs `@media { … { … } }` sont imbriqués).
      private def matching_brace(css : String, open : Int32) : Int32
        depth = 0
        i = open
        while i < css.size
          case css[i]
          when '{' then depth += 1
          when '}'
            depth -= 1
            return i if depth == 0
          end
          i += 1
        end
        css.size
      end

      private def compute(node : XML::Node) : Hash(String, Declaration)
        result = {} of String => Declaration
        matching = @rules.select(&.selector.matches?(node))
        matching.sort_by! { |r| {r.selector.specificity, r.order} }
        matching.each do |rule|
          rule.declarations.each do |d|
            # Une déclaration !important n'est écrasée que par une autre.
            next if !d.important && result[d.property]?.try(&.important)
            result[d.property] = d
          end
        end
        result
      end
    end
  end
end
