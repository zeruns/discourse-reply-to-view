# frozen_string_literal: true

# 服务端 cook 管线测试：验证 [reply] / [login] 标记在 Markdown 渲染阶段
# 产出纯结构占位容器、隐藏原文绝不进入 cooked。
RSpec.describe PrettyText, type: :component do
  describe "rtv bbcode rules" do
    it "生成 reply 占位容器且不包含隐藏原文" do
      cooked = PrettyText.cook(<<~MD)
        [reply]
        SECRET-REPLY-CONTENT
        [/reply]
      MD

      expect(cooked).to include(%(class="rtv-block rtv-reply"))
      expect(cooked).to include(%(data-rtv-type="reply"))
      expect(cooked).to include("data-rtv-index=")
      expect(cooked).to include("data-rtv-checksum=")
      expect(cooked).not_to include("SECRET-REPLY-CONTENT")
    end

    it "生成 login 占位容器且不包含隐藏原文" do
      cooked = PrettyText.cook(<<~MD)
        [login]
        SECRET-LOGIN-CONTENT
        [/login]
      MD

      expect(cooked).to include(%(class="rtv-block rtv-login"))
      expect(cooked).to include(%(data-rtv-type="login"))
      expect(cooked).not_to include("SECRET-LOGIN-CONTENT")
    end

    it "[reply=N] 输出计数值属性" do
      cooked = PrettyText.cook(<<~MD)
        [reply=3]
        SECRET-COUNT-CONTENT
        [/reply]
      MD

      expect(cooked).to include(%(data-rtv-count="3"))
      expect(cooked).not_to include("SECRET-COUNT-CONTENT")
    end

    it "非正整数计数属性被忽略（按普通 reply 处理）" do
      cooked = PrettyText.cook(<<~MD)
        [reply=abc]
        SECRET-INVALID-COUNT
        [/reply]
      MD

      expect(cooked).to include("rtv-block")
      expect(cooked).not_to include("data-rtv-count")
      expect(cooked).not_to include("SECRET-INVALID-COUNT")
    end

    it "未闭合的标记按普通文本原样输出（不报错、不生成容器）" do
      cooked = PrettyText.cook(<<~MD)
        [reply]
        SOME-TEXT
      MD

      expect(cooked).not_to include("rtv-block")
      expect(cooked).to include("[reply]")
    end

    it "标记内部支持嵌套普通 Markdown（块级结构）" do
      raw = <<~MD
        [reply]
        - item one
        - item two

        ```ruby
        puts "SECRET-CODE"
        ```
        [/reply]
      MD

      blocks = ReplyToView::Engine.extract(raw)
      expect(blocks.size).to eq(1)
      expect(blocks[0].content).to include("- item one")
      expect(blocks[0].content).to include('puts "SECRET-CODE"')

      cooked = PrettyText.cook(raw)
      expect(cooked).not_to include("SECRET-CODE")
      expect(cooked).not_to include("item one")
    end

    it "单行完整对形态被处理" do
      cooked = PrettyText.cook("[reply]SINGLE-LINE-SECRET[/reply]\n")

      expect(cooked).to include("rtv-block")
      expect(cooked).not_to include("SINGLE-LINE-SECRET")
    end

    it "行内前后有文字的标记不生效（原样输出）" do
      cooked = PrettyText.cook("prefix [reply]INLINE-SECRET[/reply]\n")
      expect(cooked).not_to include("rtv-block")

      cooked = PrettyText.cook("[reply]INLINE-SECRET[/reply] suffix\n")
      expect(cooked).not_to include("rtv-block")
    end

    it "异名标记互相嵌套时内层标记不单独生效（禁止混合解析）" do
      cooked = PrettyText.cook(<<~MD)
        [reply]
        outer SECRET-A
        [login]
        inner SECRET-B
        [/login]
        [/reply]
      MD

      # 整体作为一个 reply 块：两层原文全部丢弃，不产生独立的 login 容器
      expect(cooked.scan("rtv-block").size).to eq(1)
      expect(cooked).to include("rtv-reply")
      expect(cooked).not_to include("rtv-login")
      expect(cooked).not_to include("SECRET-A")
      expect(cooked).not_to include("SECRET-B")
    end

    it "同名标记嵌套按计数语义配对（最后一个闭合生效）" do
      raw = <<~MD
        [reply]
        outer SECRET-OUTER
        [reply]
        inner SECRET-INNER
        [/reply]
        tail SECRET-TAIL
        [/reply]
      MD

      blocks = ReplyToView::Engine.extract(raw)
      expect(blocks.size).to eq(1)
      expect(blocks[0].content).to include("SECRET-OUTER")
      expect(blocks[0].content).to include("SECRET-INNER")
      expect(blocks[0].content).to include("SECRET-TAIL")

      cooked = PrettyText.cook(raw)
      expect(cooked.scan("rtv-block").size).to eq(1)
      expect(cooked).not_to include("SECRET-OUTER")
    end

    # ============ v1.2.0 新标签 [reply-visible] / [login-visible] ============
    it "新标签 [reply-visible] 生成 reply 类型容器且不泄露原文" do
      cooked = PrettyText.cook(<<~MD)
        [reply-visible]
        NEWTAG-SECRET-A
        [/reply-visible]
      MD

      aggregate_failures do
        expect(cooked).to include(%(class="rtv-block rtv-reply"))
        expect(cooked).to include(%(data-rtv-type="reply"))
        expect(cooked).not_to include("NEWTAG-SECRET-A")
      end
    end

    it "新标签 [login-visible] 生成 login 类型容器且不泄露原文" do
      cooked = PrettyText.cook(<<~MD)
        [login-visible]
        NEWTAG-SECRET-B
        [/login-visible]
      MD

      aggregate_failures do
        expect(cooked).to include(%(class="rtv-block rtv-login"))
        expect(cooked).to include(%(data-rtv-type="login"))
        expect(cooked).not_to include("NEWTAG-SECRET-B")
      end
    end

    it "新标签计数语法 [reply-visible=N] 输出计数值" do
      cooked = PrettyText.cook(<<~MD)
        [reply-visible=3]
        NEWTAG-SECRET-C
        [/reply-visible]
      MD

      aggregate_failures do
        expect(cooked).to include(%(data-rtv-count="3"))
        expect(cooked).not_to include("NEWTAG-SECRET-C")
      end
    end

    it "新旧标签混用于同一帖子时均可解析且指纹各自对齐" do
      raw = <<~MD
        [reply]
        OLD-TAG-CONTENT
        [/reply]

        [reply-visible]
        NEW-TAG-CONTENT
        [/reply-visible]
      MD

      cooked = PrettyText.cook(raw)
      doc = Nokogiri::HTML5.fragment(cooked)
      containers = doc.css("div.rtv-block[data-rtv-index]")
      blocks = ReplyToView::Engine.extract(raw)

      expect(containers.size).to eq(2)
      expect(blocks.size).to eq(2)

      containers.sort_by { |el| el["data-rtv-index"].to_i }.each_with_index do |el, i|
        block = blocks[i]
        expect(el["data-rtv-checksum"]).to eq(block.checksum.to_s(16))
        expect(el["data-rtv-type"]).to eq(block.type.to_s)
      end

      aggregate_failures do
        expect(cooked).not_to include("OLD-TAG-CONTENT")
        expect(cooked).not_to include("NEW-TAG-CONTENT")
      end
    end

    it "新旧标签交叉嵌套视为非法形态,按普通文本原样输出" do
      cooked = PrettyText.cook(<<~MD)
        [reply]
        CROSS-TAG-SECRET
        [/reply-visible]
      MD

      aggregate_failures do
        expect(cooked).not_to include("rtv-block")
        expect(cooked).to include("CROSS-TAG-SECRET")
      end
    end

    # ============ 跨端对齐校验（安全不变量） ============
    # Ruby 提取引擎的块序列（类型 / 计数 / 指纹）必须与
    # cook 阶段写入容器的属性完全一致，否则序列化期会整帖降级为占位符
    it "Ruby 提取结果与 JS cook 容器逐块对齐（类型、计数、指纹）" do
      raw = <<~MD
        开头一段普通文字

        [login]
        SECRET-LOGIN
        [/login]

        中间一段普通文字

        [reply=2]
        SECRET-COUNT
        [/reply]

        [reply]
        SECRET-PLAIN
        [/reply]
      MD

      cooked = PrettyText.cook(raw)
      doc = Nokogiri::HTML5.fragment(cooked)
      containers = doc.css("div.rtv-block[data-rtv-index]")
      blocks = ReplyToView::Engine.extract(raw)

      expect(containers.size).to eq(blocks.size)

      containers.sort_by { |el| el["data-rtv-index"].to_i }.each_with_index do |el, i|
        block = blocks[i]
        aggregate_failures do
          expect(el["data-rtv-index"]).to eq(block.index.to_s)
          expect(el["data-rtv-type"]).to eq(block.type.to_s)
          expect(el["data-rtv-count"] || "").to eq(block.count ? block.count.to_s : "")
          # 指纹一致性：证明两端对“块内容”的切分完全一致
          expect(el["data-rtv-checksum"]).to eq(block.checksum.to_s(16))
        end
      end
    end

    it "块内容含中文与 Emoji 时跨端指纹仍然一致" do
      raw = <<~MD
        [reply]
        中文内容测试 🎉 emoji
        [/reply]
      MD

      cooked = PrettyText.cook(raw)
      el = Nokogiri::HTML5.fragment(cooked).at_css("div.rtv-block")
      block = ReplyToView::Engine.extract(raw).first

      expect(el["data-rtv-checksum"]).to eq(block.checksum.to_s(16))
    end

    it "占位文案在 CookedPostProcessor 阶段烘焙进 cooked（供搜索/邮件直读场景）" do
      post = Fabricate(:post, raw: <<~MD)
        [reply]
        SECRET-BAKE
        [/reply]
      MD

      # 与核心 ProcessPost job 相同的调用方式；job 在 post_process 后
      # 将 cp.html 写回 post.cooked，此处直接断言处理产物
      cp = CookedPostProcessor.new(post, {})
      cp.post_process

      expect(cp.html).to include("rtv-placeholder")
      expect(cp.html).not_to include("SECRET-BAKE")
    end
  end
end
