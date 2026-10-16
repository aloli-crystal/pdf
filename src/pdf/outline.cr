# Document outline (bookmarks) for PDF documents.
#
# The document outline (Section 12.3.3 of PDF spec) provides a
# hierarchical table of contents that appears in the sidebar of
# PDF viewers. Each outline item can link to a specific page/position.
#
# Ported from Prawn::Outline and PDF::Core::OutlineRoot/OutlineItem
# (prawnpdf/prawn, prawnpdf/pdf-core).

module PDF
  # Builds and manages the document outline tree.
  #
  # ```
  # outline = PDF::Outline.new(document)
  # outline.define do |o|
  #   o.section("Chapter 1", dest: PDF::Destination.fit(page1_ref)) do
  #     o.item("Section 1.1", dest: PDF::Destination.fit(page1_ref))
  #     o.item("Section 1.2", dest: PDF::Destination.fit(page2_ref))
  #   end
  #   o.section("Chapter 2", dest: PDF::Destination.fit(page3_ref))
  # end
  # ```
  class Outline
    # The document this outline belongs to.
    getter document : Document

    # Root outline object (created lazily).
    getter? root : Objects::Indirect?

    # All registered outline items by title (for add_subsection_to / insert_after).
    getter items : Hash(String, Objects::Indirect)

    # Current parent in the outline tree during definition.
    @parent : Objects::Indirect?

    # Previous sibling in the outline tree during definition.
    @prev : Objects::Indirect?

    # Count of items under root.
    @root_count : Int32 = 0

    # Count tracker per parent (object_number -> count).
    @counts : Hash(Int32, Int32)

    # First/last child tracker per parent (object_number -> {first, last}).
    @children : Hash(Int32, {Objects::Indirect, Objects::Indirect})

    # Next/prev links between siblings (object_number -> next_ref).
    @next_links : Hash(Int32, Objects::Reference)
    @prev_links : Hash(Int32, Objects::Reference)

    # Destination per item (object_number -> dest array).
    @destinations : Hash(Int32, Objects::Array)

    # Title per item (object_number -> title).
    @titles : Hash(Int32, String)

    # Parent link per item (object_number -> parent_ref).
    @parent_links : Hash(Int32, Objects::Reference)

    # Whether an item is closed (object_number -> closed).
    @closed_items : Hash(Int32, Bool)

    def initialize(@document : Document)
      @items = {} of String => Objects::Indirect
      @counts = {} of Int32 => Int32
      @children = {} of Int32 => {Objects::Indirect, Objects::Indirect}
      @next_links = {} of Int32 => Objects::Reference
      @prev_links = {} of Int32 => Objects::Reference
      @destinations = {} of Int32 => Objects::Array
      @titles = {} of Int32 => String
      @parent_links = {} of Int32 => Objects::Reference
      @closed_items = {} of Int32 => Bool
    end

    # Defines the outline structure using a block.
    def define(&block : Outline ->) : Nil
      @parent = ensure_root
      @prev = nil
      yield self
    end

    # Adds an outline section (a node that can have children).
    #
    # ```
    # outline.define do |o|
    #   o.section("Chapter 1", dest: dest_array) do
    #     o.item("Page 1", dest: page1_dest)
    #   end
    # end
    # ```
    def section(title : String, dest : Objects::Array? = nil, closed : Bool = false, &block : ->) : Nil
      item_obj = create_item(title, dest, closed)
      establish_relations(item_obj)
      increase_count

      # Enter this section as parent
      saved_parent = @parent
      saved_prev = @prev
      @parent = item_obj
      @prev = nil

      yield

      # Restore
      @prev = item_obj
      @parent = saved_parent
    end

    # Adds an outline section without children.
    def section(title : String, dest : Objects::Array? = nil, closed : Bool = false) : Nil
      item_obj = create_item(title, dest, closed)
      establish_relations(item_obj)
      increase_count
      @prev = item_obj
    end

    # Adds a leaf item to the outline (no children).
    #
    # ```
    # outline.define do |o|
    #   o.item("Introduction", dest: dest_array)
    # end
    # ```
    def item(title : String, dest : Objects::Array? = nil) : Nil
      item_obj = create_item(title, dest, false)
      establish_relations(item_obj)
      increase_count
      @prev = item_obj
    end

    # Finalizes the outline and returns the root reference for the catalog,
    # or nil if no outline was defined.
    def finalize! : Objects::Reference?
      root_obj = @root
      return unless root_obj

      # Build the root dictionary
      root_dict = Objects::Dictionary.new
      root_dict["Type"] = Objects::Name.new("Outlines")
      root_dict["Count"] = Objects::Number.new(@root_count)

      if children = @children[root_obj.object_number]?
        root_dict["First"] = children[0].reference
        root_dict["Last"] = children[1].reference
      end

      root_obj.value = root_dict

      # Build all item dictionaries
      @items.each do |title, item_obj|
        obj_num = item_obj.object_number
        item_dict = Objects::Dictionary.new
        item_dict["Title"] = Objects::Str.unicode(title)

        if parent_ref = @parent_links[obj_num]?
          item_dict["Parent"] = parent_ref
        end

        if dest = @destinations[obj_num]?
          item_dict["Dest"] = dest
        end

        count = @counts[obj_num]? || 0
        if count > 0
          closed = @closed_items[obj_num]? || false
          item_dict["Count"] = Objects::Number.new(closed ? -count : count)
        end

        if children = @children[obj_num]?
          item_dict["First"] = children[0].reference
          item_dict["Last"] = children[1].reference
        end

        if next_ref = @next_links[obj_num]?
          item_dict["Next"] = next_ref
        end

        if prev_ref = @prev_links[obj_num]?
          item_dict["Prev"] = prev_ref
        end

        item_obj.value = item_dict
      end

      root_obj.reference
    end

    private def ensure_root : Objects::Indirect
      @root ||= begin
        # Register a placeholder dictionary; will be replaced in finalize!
        @document.register_object(Objects::Dictionary.new)
      end
    end

    private def create_item(title : String, dest : Objects::Array?, closed : Bool) : Objects::Indirect
      # Register a placeholder; real dictionary built in finalize!
      item_obj = @document.register_object(Objects::Dictionary.new)

      @titles[item_obj.object_number] = title
      @destinations[item_obj.object_number] = dest if dest
      @closed_items[item_obj.object_number] = closed if closed

      parent = @parent.not_nil!
      @parent_links[item_obj.object_number] = parent.reference

      @items[title] = item_obj
      item_obj
    end

    private def establish_relations(item_obj : Objects::Indirect) : Nil
      parent = @parent.not_nil!
      parent_num = parent.object_number

      # Set prev/next links
      if prev = @prev
        @next_links[prev.object_number] = item_obj.reference
        @prev_links[item_obj.object_number] = prev.reference
      end

      # Update parent's first/last children
      if existing = @children[parent_num]?
        # Update last child
        @children[parent_num] = {existing[0], item_obj}
      else
        # First child
        @children[parent_num] = {item_obj, item_obj}
      end
    end

    private def increase_count : Nil
      # Increment count for all ancestors up to root
      parent = @parent
      while parent
        parent_num = parent.object_number
        root_obj = @root

        if root_obj && parent_num == root_obj.object_number
          @root_count += 1
          break
        else
          @counts[parent_num] = (@counts[parent_num]? || 0) + 1
          # Walk up to parent's parent
          if parent_ref = @parent_links[parent_num]?
            # Find the indirect object for this reference
            found = @document.objects.find { |obj| obj.object_number == parent_ref.object_number }
            parent = found
          else
            break
          end
        end
      end
    end
  end
end
