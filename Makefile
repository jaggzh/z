SRCFILES=\
		PRECEDENCE.md \
		z \
		lib/ZChat.pm \
		lib/ZChat/Utils.pm \
		lib/ZChat/ContextManager.pm \
		lib/ZChat/Storage.pm \
		lib/ZChat/Config.pm \
		lib/ZChat/Core.pm \
		lib/ZChat/Pin.pm \
		lib/ZChat/History.pm \
		lib/ZChat/SystemPrompt.pm \
		lib/ZChat/ParentID.pm \
		lib/ZChat/ansi.pm \

.PHONY: tags
tags:
	ctags $(SRCFILES)

llmcat:
	ls-cat-for-llm $(SRCFILES)

vi:
	vim \
		$(SRCFILES) \
		Makefile \

# Leave blank line above
