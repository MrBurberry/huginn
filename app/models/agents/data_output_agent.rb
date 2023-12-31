module Agents
  class DataOutputAgent < Agent
    include WebRequestConcern

    cannot_be_scheduled!
    cannot_create_events!

    description do
      <<~MD
        The Data Output Agent outputs received events as either RSS or JSON.  Use it to output a public or private stream of Huginn data.

        This Agent will output data at:

        `https://#{ENV['DOMAIN']}#{Rails.application.routes.url_helpers.web_requests_path(agent_id: ':id', user_id:, secret: ':secret', format: :xml)}`

        where `:secret` is one of the allowed secrets specified in your options and the extension can be `xml` or `json`.

        You can setup multiple secrets so that you can individually authorize external systems to
        access your Huginn data.

        Options:

          * `secrets` - An array of tokens that the requestor must provide for light-weight authentication.
          * `expected_receive_period_in_days` - How often you expect data to be received by this Agent from other Agents.
          * `template` - A JSON object representing a mapping between item output keys and incoming event values.  Use [Liquid](https://github.com/huginn/huginn/wiki/Formatting-Events-using-Liquid) to format the values.  Values of the `link`, `title`, `description` and `icon` keys will be put into the \\<channel\\> section of RSS output.  Value of the `self` key will be used as URL for this feed itself, which is useful when you serve it via reverse proxy.  The `item` key will be repeated for every Event.  The `pubDate` key for each item will have the creation time of the Event unless given.
          * `events_to_show` - The number of events to output in RSS or JSON. (default: `40`)
          * `ttl` - A value for the \\<ttl\\> element in RSS output. (default: `60`)
          * `ns_dc` - Add [DCMI Metadata Terms namespace](http://purl.org/dc/elements/1.1/) in output xml
          * `ns_media` - Add [yahoo media namespace](https://en.wikipedia.org/wiki/Media_RSS) in output xml
          * `ns_itunes` - Add [itunes compatible namespace](http://lists.apple.com/archives/syndication-dev/2005/Nov/msg00002.html) in output xml
          * `rss_content_type` - Content-Type for RSS output (default: `application/rss+xml`)
          * `response_headers` - An object with any custom response headers. (example: `{"Access-Control-Allow-Origin": "*"}`)
          * `push_hubs` - Set to a list of PubSubHubbub endpoints you want to publish an update to every time this agent receives an event. (default: none)  Popular hubs include [Superfeedr](https://pubsubhubbub.superfeedr.com/) and [Google](https://pubsubhubbub.appspot.com/).  Note that publishing updates will make your feed URL known to the public, so if you want to keep it secret, set up a reverse proxy to serve your feed via a safe URL and specify it in `template.self`.

        If you'd like to output RSS tags with attributes, such as `enclosure`, use something like the following in your `template`:

            "enclosure": {
              "_attributes": {
                "url": "{{media_url}}",
                "length": "1234456789",
                "type": "audio/mpeg"
              }
            },
            "another_tag": {
              "_attributes": {
                "key": "value",
                "another_key": "another_value"
              },
              "_contents": "tag contents (can be an object for nesting)"
            }

        # Ordering events

        #{description_events_order('events')}

        DataOutputAgent will select the last `events_to_show` entries of its received events sorted in the order specified by `events_order`, which is defaulted to the event creation time.
        So, if you have multiple source agents that may create many events in a run, you may want to either increase `events_to_show` to have a larger "window", or specify the `events_order` option to an appropriate value (like `date_published`) so events from various sources are properly mixed in the resulted feed.

        There is also an option `events_list_order` that only controls the order of events listed in the final output, without attempting to maintain a total order of received events.  It has the same format as `events_order` and is defaulted to `#{Utils.jsonify(DEFAULT_EVENTS_ORDER['events_list_order'])}` so the selected events are listed in reverse order like most popular RSS feeds list their articles.

        # Liquid Templating

        In [Liquid](https://github.com/huginn/huginn/wiki/Formatting-Events-using-Liquid) templating, the following variable is available:

        * `events`: An array of events being output, sorted in the given order, up to `events_to_show` in number.  For example, if source events contain a site title in the `site_title` key, you can refer to it in `template.title` by putting `{{events.first.site_title}}`.

      MD
    end

    def default_options
      {
        "secrets" => ["a-secret-key"],
        "expected_receive_period_in_days" => 2,
        "template" => {
          "title" => "XKCD comics as a feed",
          "description" => "This is a feed of recent XKCD comics, generated by Huginn",
          "item" => {
            "title" => "{{title}}",
            "description" => "Secret hovertext: {{hovertext}}",
            "link" => "{{url}}"
          }
        },
        "ns_media" => "true"
      }
    end

    def working?
      last_receive_at && last_receive_at > options['expected_receive_period_in_days'].to_i.days.ago && !recent_error_logs?
    end

    def validate_options
      if options['secrets'].is_a?(Array) && options['secrets'].length > 0
        options['secrets'].each do |secret|
          case secret
          when %r{[/.]}
            errors.add(:base, "secret may not contain a slash or dot")
          when String
          else
            errors.add(:base, "secret must be a string")
          end
        end
      else
        errors.add(:base, "Please specify one or more secrets for 'authenticating' incoming feed requests")
      end

      unless options['expected_receive_period_in_days'].present? && options['expected_receive_period_in_days'].to_i > 0
        errors.add(:base,
                   "Please provide 'expected_receive_period_in_days' to indicate how many days can pass before this Agent is considered to be not working")
      end

      unless options['template'].present? && options['template']['item'].present? && options['template']['item'].is_a?(Hash)
        errors.add(:base, "Please provide template and template.item")
      end

      case options['push_hubs']
      when nil
      when Array
        options['push_hubs'].each do |hub|
          case hub
          when /\{/
            # Liquid templating
          when String
            begin
              URI.parse(hub)
            rescue URI::Error
              errors.add(:base, "invalid URL found in push_hubs")
              break
            end
          else
            errors.add(:base, "push_hubs must be an array of endpoint URLs")
            break
          end
        end
      else
        errors.add(:base, "push_hubs must be an array")
      end
    end

    def events_to_show
      (interpolated['events_to_show'].presence || 40).to_i
    end

    def feed_ttl
      (interpolated['ttl'].presence || 60).to_i
    end

    def feed_title
      interpolated['template']['title'].presence || "#{name} Event Feed"
    end

    def feed_link
      interpolated['template']['link'].presence || "https://#{ENV['DOMAIN']}"
    end

    def feed_url(options = {})
      interpolated['template']['self'].presence ||
        feed_link + Rails.application.routes.url_helpers.web_requests_path(
          agent_id: id || ':id',
          user_id:,
          secret: options[:secret],
          format: options[:format]
        )
    end

    def feed_icon
      interpolated['template']['icon'].presence || feed_link + '/favicon.ico'
    end

    def itunes_icon
      if boolify(interpolated['ns_itunes'])
        "<itunes:image href=#{feed_icon.encode(xml: :attr)} />"
      end
    end

    def feed_description
      interpolated['template']['description'].presence || "A feed of Events received by the '#{name}' Huginn Agent"
    end

    def rss_content_type
      interpolated['rss_content_type'].presence || 'application/rss+xml'
    end

    def xml_namespace
      namespaces = ['xmlns:atom="http://www.w3.org/2005/Atom"']

      if boolify(interpolated['ns_dc'])
        namespaces << 'xmlns:dc="http://purl.org/dc/elements/1.1/"'
      end
      if boolify(interpolated['ns_media'])
        namespaces << 'xmlns:media="http://search.yahoo.com/mrss/"'
      end
      if boolify(interpolated['ns_itunes'])
        namespaces << 'xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"'
      end
      namespaces.join(' ')
    end

    def push_hubs
      interpolated['push_hubs'].presence || []
    end

    DEFAULT_EVENTS_ORDER = {
      'events_order' => nil,
      'events_list_order' => [["{{_index_}}", "number", true]],
    }

    def events_order(key = SortableEvents::EVENTS_ORDER_KEY)
      super || DEFAULT_EVENTS_ORDER[key]
    end

    def latest_events(reload = false)
      received_events = received_events().reorder(id: :asc)

      events =
        if (event_ids = memory[:event_ids]) &&
            memory[:events_order] == events_order &&
            memory[:events_to_show] >= events_to_show
          received_events.where(id: event_ids).to_a
        else
          memory[:last_event_id] = nil
          reload = true
          []
        end

      if reload
        memory[:events_order] = events_order
        memory[:events_to_show] = events_to_show

        new_events =
          if last_event_id = memory[:last_event_id]
            received_events.where(Event.arel_table[:id].gt(last_event_id)).to_a
          else
            source_ids.flat_map { |source_id|
              # dig twice as many events as the number of
              # `events_to_show`
              received_events.where(agent_id: source_id)
                .last(2 * events_to_show)
            }.sort_by(&:id)
          end

        unless new_events.empty?
          memory[:last_event_id] = new_events.last.id
          events.concat(new_events)
        end
      end

      events = sort_events(events).last(events_to_show)

      if reload
        memory[:event_ids] = events.map(&:id)
      end

      events
    end

    def receive_web_request(params, method, format)
      unless interpolated['secrets'].include?(params['secret'])
        if format =~ /json/
          return [{ error: "Not Authorized" }, 401]
        else
          return ["Not Authorized", 401]
        end
      end

      source_events = sort_events(latest_events, 'events_list_order')

      interpolate_with('events' => source_events) do
        items = source_events.map do |event|
          interpolated = interpolate_options(options['template']['item'], event)
          interpolated['guid'] = {
            '_attributes' => { 'isPermaLink' => 'false' },
            '_contents' => interpolated['guid'].presence || event.id
          }
          date_string = interpolated['pubDate'].to_s
          date =
            begin
              Time.zone.parse(date_string) # may return nil
            rescue StandardError => e
              error "Error parsing a \"pubDate\" value \"#{date_string}\": #{e.message}"
              nil
            end || event.created_at
          interpolated['pubDate'] = date.rfc2822.to_s
          interpolated
        end

        now = Time.now

        if format =~ /json/
          content = {
            'title' => feed_title,
            'description' => feed_description,
            'pubDate' => now,
            'items' => simplify_item_for_json(items)
          }

          return [content, 200, "application/json", interpolated['response_headers'].presence]
        else
          hub_links = push_hubs.map { |hub|
            <<-XML
 <atom:link rel="hub" href=#{hub.encode(xml: :attr)}/>
            XML
          }.join

          items = items_to_xml(items)

          return [<<~XML, 200, rss_content_type, interpolated['response_headers'].presence]
            <?xml version="1.0" encoding="UTF-8" ?>
            <rss version="2.0" #{xml_namespace}>
            <channel>
             <atom:link href=#{feed_url(secret: params['secret'], format: :xml).encode(xml: :attr)} rel="self" type="application/rss+xml" />
             <atom:icon>#{feed_icon.encode(xml: :text)}</atom:icon>
             #{itunes_icon}
            #{hub_links}
             <title>#{feed_title.encode(xml: :text)}</title>
             <description>#{feed_description.encode(xml: :text)}</description>
             <link>#{feed_link.encode(xml: :text)}</link>
             <lastBuildDate>#{now.rfc2822.to_s.encode(xml: :text)}</lastBuildDate>
             <pubDate>#{now.rfc2822.to_s.encode(xml: :text)}</pubDate>
             <ttl>#{feed_ttl}</ttl>
            #{items}
            </channel>
            </rss>
          XML
        end
      end
    end

    def receive(incoming_events)
      url = feed_url(secret: interpolated['secrets'].first, format: :xml)

      # Reload new events and update cache
      latest_events(true)

      push_hubs.each do |hub|
        push_to_hub(hub, url)
      end
    end

    private

    class XMLNode
      def initialize(tag_name, attributes, contents)
        @tag_name = tag_name
        @attributes = attributes
        @contents = contents
      end

      def to_xml(options)
        if @contents.is_a?(Hash)
          options[:builder].tag! @tag_name, @attributes do
            @contents.each { |key, value|
              ActiveSupport::XmlMini.to_tag(key, value, options.merge(skip_instruct: true))
            }
          end
        else
          options[:builder].tag! @tag_name, @attributes, @contents
        end
      end
    end

    def simplify_item_for_xml(item)
      if item.is_a?(Hash)
        item.each.with_object({}) do |(key, value), memo|
          memo[key] =
            if value.is_a?(Hash)
              if value.key?('_attributes') || value.key?('_contents')
                XMLNode.new(key, value['_attributes'], simplify_item_for_xml(value['_contents']))
              else
                simplify_item_for_xml(value)
              end
            else
              value
            end
        end
      elsif item.is_a?(Array)
        item.map { |value| simplify_item_for_xml(value) }
      else
        item
      end
    end

    def simplify_item_for_json(item)
      if item.is_a?(Hash)
        item.each.with_object({}) do |(key, value), memo|
          if value.is_a?(Hash)
            if value.key?('_attributes') || value.key?('_contents')
              contents =
                if value['_contents'] && value['_contents'].is_a?(Hash)
                  simplify_item_for_json(value['_contents'])
                elsif value['_contents']
                  { "contents" => value['_contents'] }
                else
                  {}
                end

              memo[key] = contents.merge(value['_attributes'] || {})
            else
              memo[key] = simplify_item_for_json(value)
            end
          else
            memo[key] = value
          end
        end
      elsif item.is_a?(Array)
        item.map { |value| simplify_item_for_json(value) }
      else
        item
      end
    end

    def items_to_xml(items)
      simplify_item_for_xml(items)
        .to_xml(skip_types: true, root: "items", skip_instruct: true, indent: 1)
        .gsub(%r{
          (?<indent> ^\ + ) < (?<tagname> [^> ]+ ) > \n
          (?<children>
            (?: \k<indent> \  < \k<tagname> (?:\ [^>]*)? > [^<>]*? </ \k<tagname> > \n )+
          )
          \k<indent> </ \k<tagname> > \n
        }mx) { $~[:children].gsub(/^ /, '') } # delete redundant nesting of array elements
        .gsub(%r{
          (?<indent> ^\ + ) < [^> ]+ /> \n
        }mx, '') # delete empty elements
        .gsub(%r{^</?items>\n}, '')
    end

    def push_to_hub(hub, url)
      hub_uri =
        begin
          URI.parse(hub)
        rescue URI::Error
          nil
        end

      if !hub_uri.is_a?(URI::HTTP)
        error "Invalid push endpoint: #{hub}"
        return
      end

      log "Pushing #{url} to #{hub_uri}"

      return if dry_run?

      begin
        faraday.post hub_uri, {
          'hub.mode' => 'publish',
          'hub.url' => url
        }
      rescue StandardError => e
        error "Push failed: #{e.message}"
      end
    end
  end
end
