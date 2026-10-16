module PDF
  module ColorSpaces
    # NChannel colour space (PDF spec § 8.6.6.5) — a specialised
    # `DeviceN` whose attributes dictionary carries `/Subtype
    # /NChannel`. It is the modern form for spaces that mix process
    # inks with one or more spot colorants : the optional `/Process`
    # entry names the process colour space and which colorants feed
    # it, letting a conforming renderer composite spot and process
    # colours correctly rather than only through the shared tint
    # transform.
    #
    # Array form (identical to DeviceN, the attributes dictionary is
    # always present) :
    # `[/DeviceN [/n1 /n2 ...] <alternate> <tintTransform> <attributes>]`
    # with `<attributes>` = `<< /Subtype /NChannel /Colorants << … >>
    # [/Process << … >>] >>`.
    #
    # ## Spot colorants and PDF/A-2 § 6.2.4.4
    #
    # NChannel is subject to the same `/Colorants` requirement as
    # `DeviceN` : every spot colorant must have an entry. That logic
    # is inherited from `DeviceN` ; this class only adds `/Subtype
    # /NChannel` and the optional `/Process` description.
    #
    # ## Example
    #
    # ```
    # # CMYK process + one spot ink, all over a FOGRA39 fallback.
    # nchan = PDF::ColorSpaces::NChannel.new(
    #   names: ["Cyan", "Magenta", "Yellow", "Black", "Pantone 877 C"],
    #   alternate: PDF::ColorSpaces::ICCBased.fogra39,
    #   c1_per_component: [
    #     [1.0, 0.0, 0.0, 0.0],
    #     [0.0, 1.0, 0.0, 0.0],
    #     [0.0, 0.0, 1.0, 0.0],
    #     [0.0, 0.0, 0.0, 1.0],
    #     [0.0, 0.0, 0.0, 0.2], # spot
    #   ],
    #   process_components: ["Cyan", "Magenta", "Yellow", "Black"],
    # )
    # ```
    class NChannel < DeviceN
      # Names of the colorants that feed the process colour space, in
      # channel order (e.g. `["Cyan", "Magenta", "Yellow", "Black"]`).
      # `nil` = no `/Process` entry emitted. When given, the process
      # colour space is this space's `alternate`, so the list length
      # must equal `alternate.num_components` and every name must also
      # appear in `names`.
      getter process_components : Array(String)?

      # `/MixingHints /Solidities` — relative opacity of each colorant
      # in `[0, 1]`. Keys are colorant names (or `"Default"`). `nil` =
      # entry omitted.
      getter solidities : Hash(String, Float64)?

      # `/MixingHints /PrintingOrder` — the order in which colorants
      # are laid down. Required by ISO 32000-1 § 8.6.6.5 when
      # `solidities` is given.
      getter printing_order : Array(String)?

      # `/MixingHints /DotGain` — per-colorant dot-gain transfer.
      # Each value is the exponent `N` of a Type-2 function
      # `f(t) = t^N` over domain/range `[0, 1]` (`N < 1` boosts
      # midtones). Keys are colorant names (or `"Default"`).
      getter dot_gain : Hash(String, Float64)?

      def initialize(
        *,
        names : Array(String),
        alternate : ICCBased,
        c1_per_component : Array(Array(Float64)),
        @process_components : Array(String)? = nil,
        @solidities : Hash(String, Float64)? = nil,
        @printing_order : Array(String)? = nil,
        @dot_gain : Hash(String, Float64)? = nil,
      )
        super(names: names, alternate: alternate, c1_per_component: c1_per_component)
        if components = @process_components
          unless components.size == @alternate.num_components
            raise ArgumentError.new("NChannel /Process needs #{@alternate.num_components} component name(s) to match the #{@alternate.num_components}-channel alternate")
          end
          missing = components.reject { |c| @names.includes?(c) }
          unless missing.empty?
            raise ArgumentError.new("NChannel /Process components #{missing} are not among the colorant names")
          end
        end

        validate_mixing_hints!
      end

      # Checks the `/MixingHints` inputs against ISO 32000-1 § 8.6.6.5.
      private def validate_mixing_hints!
        if solidities = @solidities
          solidities.each do |name, value|
            unless value >= 0.0 && value <= 1.0
              raise ArgumentError.new("NChannel /Solidities['#{name}'] must be in [0, 1], got #{value}")
            end
            unless name == "Default" || @names.includes?(name)
              raise ArgumentError.new("NChannel /Solidities key '#{name}' is neither a colorant name nor 'Default'")
            end
          end
          # § 8.6.6.5 : PrintingOrder is required when Solidities is given.
          raise ArgumentError.new("NChannel /Solidities requires /PrintingOrder") unless @printing_order
        end

        if order = @printing_order
          missing = order.reject { |n| @names.includes?(n) }
          unless missing.empty?
            raise ArgumentError.new("NChannel /PrintingOrder names #{missing} are not among the colorant names")
          end
        end

        if dot_gain = @dot_gain
          dot_gain.each do |name, exponent|
            unless exponent > 0.0
              raise ArgumentError.new("NChannel /DotGain['#{name}'] exponent must be > 0, got #{exponent}")
            end
            unless name == "Default" || @names.includes?(name)
              raise ArgumentError.new("NChannel /DotGain key '#{name}' is neither a colorant name nor 'Default'")
            end
          end
        end
      end

      # Extends `DeviceN`'s attributes (the `/Colorants` dictionary,
      # built only when spot colorants are present) with the
      # `/Subtype /NChannel` marker — always emitted, so an NChannel
      # always carries an attributes dictionary — plus the optional
      # `/Process` and `/MixingHints` sub-dictionaries.
      private def build_attributes(alternate_ref : Objects::Reference) : Objects::Dictionary?
        attributes = super || Objects::Dictionary.new
        attributes["Subtype"] = Objects::Name.new("NChannel")

        if components = @process_components
          process = Objects::Dictionary.new
          process["ColorSpace"] = ColorSpaces.icc_based_space(alternate_ref)
          component_names = Objects::Array.new
          components.each { |n| component_names << Objects::Name.new(n) }
          process["Components"] = component_names
          attributes["Process"] = process
        end

        if hints = build_mixing_hints
          attributes["MixingHints"] = hints
        end

        attributes
      end

      # Builds the `/MixingHints` dictionary (§ 8.6.6.5) from
      # `solidities` / `printing_order` / `dot_gain`, or `nil` when
      # none were supplied.
      private def build_mixing_hints : Objects::Dictionary?
        return unless @solidities || @printing_order || @dot_gain
        hints = Objects::Dictionary.new

        if solidities = @solidities
          dict = Objects::Dictionary.new
          solidities.each { |name, value| dict[name] = Objects::Number.new(value) }
          hints["Solidities"] = dict
        end

        if order = @printing_order
          arr = Objects::Array.new
          order.each { |name| arr << Objects::Name.new(name) }
          hints["PrintingOrder"] = arr
        end

        if dot_gain = @dot_gain
          dict = Objects::Dictionary.new
          dot_gain.each { |name, exponent| dict[name] = build_dot_gain_function(exponent) }
          hints["DotGain"] = dict
        end

        hints
      end

      # A Type-2 dot-gain transfer function `f(t) = t^exponent` over
      # domain and range `[0, 1]` (one input, one output).
      private def build_dot_gain_function(exponent : Float64) : Objects::Dictionary
        f = Objects::Dictionary.new
        f["FunctionType"] = Objects::Number.new(2)
        f["Domain"] = Objects::Array.new([0, 1])
        f["Range"] = Objects::Array.new([0, 1])
        c0 = Objects::Array.new
        c0 << Objects::Number.new(0)
        f["C0"] = c0
        c1 = Objects::Array.new
        c1 << Objects::Number.new(1)
        f["C1"] = c1
        f["N"] = Objects::Number.new(exponent)
        f
      end
    end
  end
end
