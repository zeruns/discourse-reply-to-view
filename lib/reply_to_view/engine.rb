# frozen_string_literal: true

# 作者: discourse-reply-to-view
#
# 块提取引擎：从 raw 文本中提取 [reply]...[/reply] / [login]...[/login] / [reply=N]...[/reply] 标记块。
#
# 【安全架构 - 核心组件】
# cooked 字段在 cook 阶段即丢弃隐藏原文（见 assets/javascripts/discourse-markdown/server-rtv-rule.js），
# 序列化阶段的原文回填以本引擎对 raw 的提取结果为唯一来源。
# 因此提取算法必须与 Discourse 核心 markdown-it bbcode 引擎的配对语义保持一致：
#
#   1. 块级形态：开标记独占一行（允许行首缩进与尾随空白），逐行扫描同名闭合标记；
#      同名标记嵌套时按计数语义配对（最后一个闭合标记生效），
#      异名标记互相嵌套时内层标记被视为外层块的普通内容，不单独生效（禁止混合解析）；
#   2. 单行形态：整行恰好为一个完整的开闭对（贪婪匹配最后一个闭合标记，
#      与核心引擎 findInlineCloseTag 的反向扫描语义一致）；
#   3. 未闭合 / 非法形态：按普通文本原样处理，不产生块、不报错中断；
#   4. 残余的解析差异（极端缩进、复杂属性等罕见场景）由 cook 时写入容器的
#      data-rtv-checksum 指纹校验兜底（见 CookedInjector），校验失败时整帖
#      降级为占位符输出 —— 宁可整帖隐藏，绝不允许发生块内容错位注入。
module ReplyToView
  class Engine
    # 提取出的单个标记块
    #   type:     :reply 或 :login
    #   count:    [reply=N] 的 N（正整数），未指定或非法时为 nil
    #   content:  标记内部的原始 Markdown 文本（不包含标记本身）
    #   index:    本帖内按出现顺序的 1 基序号，与 cook 阶段生成的 data-rtv-index 对应
    #   checksum: content 的 FNV-1a 指纹（与 JS 端算法一致），用于跨端对齐校验
    #   range:    块在 raw 中占据的行号区间 [起始行, 结束行]（含端点，0 基），供 raw 净化重写使用
    Block = Struct.new(:type, :count, :content, :index, :checksum, :range, keyword_init: true)

    # 标记名：v1.2.0 起主用 [reply-visible] / [login-visible]（更明确、避免与
    # 其他插件或普通文本撞名）；旧标签 [reply] / [login] 向后兼容保留 ——
    # 若移除旧标签,历史帖子的隐藏内容将以明文渲染,构成泄露,故不可移除
    TAG_NAMES = %w[reply-visible login-visible reply login].freeze

    # 开标记：整行 strip 后恰好是 [reply-visible] / [login] / [reply-visible=xxx] 等
    # 属性值语义与核心引擎 parseBBCodeTag 对齐：非空白、非 ] 的连续字符
    OPEN_RE = /\A\[(reply-visible|login-visible|reply|login)(?:=([^\]\s]+))?\]\z/
    # 闭标记：整行 strip 后恰好是 [/reply-visible] / [/login] 等
    CLOSE_RE = /\A\[\/(reply-visible|login-visible|reply|login)\]\z/
    # 单行完整对：整行 strip 后恰好为完整的开闭对（回溯到最后一个闭标记）
    INLINE_RE = /\A\[(reply-visible|login-visible|reply|login)(?:=([^\]\s]+))?\](.+)\[\/\1\]\z/

    class << self
      # 快速检测文本是否包含本插件标记（新旧标签均识别,轻量正则用于 early-exit）
      def contains_marks?(text)
        !text.nil? && text.match?(/\[\/?\[?(reply|login)(?:-visible)?(?:=|\])/i)
      end

      # 从 raw 提取全部标记块（按出现顺序）
      def extract(raw)
        blocks = []
        return blocks if raw.blank?

        lines = raw.split("\n", -1)
        i = 0
        while i < lines.length
          stripped = lines[i].strip

          if (m = OPEN_RE.match(stripped))
            # —— 块级形态：逐行扫描同名闭合标记（嵌套计数）——
            tag = m[1]
            depth = 1
            j = i + 1
            content_lines = []
            closed = false
            while j < lines.length
              s = lines[j].strip
              if (cm = CLOSE_RE.match(s)) && cm[1] == tag
                if depth == 1
                  closed = true
                  break
                else
                  depth -= 1
                  content_lines << lines[j]
                end
              elsif (om = OPEN_RE.match(s)) && om[1] == tag
                # 同名内层开标记：计数 +1，作为外层内容保留
                depth += 1
                content_lines << lines[j]
              else
                content_lines << lines[j]
              end
              j += 1
            end

            if closed
              content = content_lines.join("\n")
              blocks << build_block(tag, m[2], content, blocks.size + 1, [i, j])
              i = j + 1
              next
            end
            # 未闭合：本行按普通文本处理，继续扫描（与核心引擎“不自动闭合”语义一致）
            i += 1
          elsif (im = INLINE_RE.match(stripped))
            # —— 单行完整对形态 ——
            content = im[3]
            blocks << build_block(im[1], im[2], content, blocks.size + 1, [i, i])
            i += 1
          else
            i += 1
          end
        end
        blocks
      end

      # 将 raw 中所有标记块替换为占位提示文本（保留块外文本不变），
      # 用于 raw 导出类接口的脱敏输出。
      def replace_blocks(raw, placeholder)
        return raw if raw.blank?
        lines = raw.split("\n", -1)
        extract(raw).each do |block|
          (block.range[0]..block.range[1]).each { |idx| lines[idx] = nil }
          # 占位文本插在块首行位置，保持上下文可读
          lines[block.range[0]] = placeholder
        end
        lines.compact.join("\n")
      end

      # 剥离文本内部的嵌套标记（保留标记内的正文）。
      # 用于解锁注入前的块内容预处理：注入内容会重新走 Markdown 渲染，
      # 若保留嵌套标记会再次生成空占位容器，故展开为普通内容。
      def strip_marks(content)
        return content if content.blank?

        lines = content.split("\n", -1)
        extract(content).each do |block|
          start_line, end_line = block.range
          if start_line == end_line
            # 单行完整对：整行替换为标记内部内容
            lines[start_line] = block.content
          else
            # 块级形态：仅移除开 / 闭标记行，正文行原样保留
            lines[start_line] = nil
            lines[end_line] = nil
          end
        end
        lines.compact.join("\n")
      end

      private

      # 标签名归一化为内部类型:reply-visible/reply → :reply,
      # login-visible/login → :login（容器 class 与 CSS 沿用 rtv-reply/rtv-login）
      def normalize_type(tag)
        tag.start_with?("reply") ? :reply : :login
      end

      def build_block(tag, raw_count, content, index, range)
        Block.new(
          type: normalize_type(tag),
          count: parse_count(raw_count),
          content: content,
          index: index,
          checksum: Checksum.fnv1a(content),
          range: range,
        )
      end

      # 属性值必须是正整数字符串才视为有效计数，否则按普通 [reply] 处理。
      # 与 server-rtv-rule.js 中的判定逻辑保持一致。
      def parse_count(raw)
        return nil if raw.blank?
        return nil unless raw.match?(/\A\d+\z/)
        n = raw.to_i
        n.positive? ? n : nil
      end
    end
  end

  # FNV-1a 32 位指纹（按 Unicode 码点迭代）。
  # JS 端（server-rtv-rule.js）实现了完全相同的算法，两侧指纹一致
  # 是“序列化期注入内容与 cook 期占位容器逐一对齐”的安全前提。
  module Checksum
    FNV_OFFSET = 0x811c9dc5
    FNV_PRIME = 0x01000193

    class << self
      def fnv1a(str)
        hash = FNV_OFFSET
        str.each_char do |ch|
          hash ^= ch.ord
          hash = (hash * FNV_PRIME) & 0xffffffff
        end
        hash
      end

      # 与 JS 端 toString(16) 输出格式对齐（无前导 0 补齐，两端都以小写十六进制比较）
      def hex(str)
        fnv1a(str).to_s(16)
      end
    end
  end
end
