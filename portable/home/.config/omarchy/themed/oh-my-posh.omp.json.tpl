{
  "$schema": "https://raw.githubusercontent.com/JanDeDobbeleer/oh-my-posh/main/themes/schema.json",
  "version": 4,
  "final_space": true,
  "palette": {
    "bg": "{{ background }}",
    "surface": "{{ lighter_background }}",
    "fg": "{{ foreground }}",
    "muted": "{{ muted }}",
    "accent": "{{ accent }}",
    "red": "{{ red }}",
    "yellow": "{{ yellow }}",
    "green": "{{ green }}",
    "cyan": "{{ cyan }}",
    "magenta": "{{ magenta }}"
  },
  "blocks": [
    {
      "type": "prompt",
      "alignment": "left",
      "segments": [
        {
          "type": "os",
          "style": "diamond",
          "leading_diamond": "",
          "trailing_diamond": "",
          "foreground": "p:bg",
          "background": "p:red",
          "template": "  "
        },
        {
          "style": "powerline",
          "powerline_symbol": "",
          "foreground": "p:fg",
          "background": "p:surface",
          "type": "session",
          "template": "{{ if .SSHSession }}  {{ .UserName }}@{{ .HostName }} {{ end }}"
        },
        {
          "style": "powerline",
          "powerline_symbol": "",
          "foreground": "p:fg",
          "background": "p:surface",
          "type": "path",
          "template": "  {{ .Path }} ",
          "options": {
            "style": "agnoster_short",
            "max_depth": 3,
            "home_icon": "~"
          }
        },
        {
          "style": "powerline",
          "powerline_symbol": "",
          "foreground": "p:bg",
          "background": "p:accent",
          "type": "git",
          "background_templates": [
            "{{ if or (.Working.Changed) (.Staging.Changed) }}p:yellow{{ end }}",
            "{{ if or (gt .Ahead 0) (gt .Behind 0) }}p:cyan{{ end }}"
          ],
          "options": {
            "fetch_status": true,
            "fetch_stash_count": true,
            "fetch_upstream_icon": true
          },
          "template": " {{ .UpstreamIcon }}{{ .HEAD }}{{ if .BranchStatus }} {{ .BranchStatus }}{{ end }}{{ if .Working.Changed }}  {{ .Working.String }}{{ end }}{{ if .Staging.Changed }}  {{ .Staging.String }}{{ end }}{{ if gt .StashCount 0 }}  {{ .StashCount }}{{ end }} "
        },
        {
          "style": "powerline",
          "powerline_symbol": "",
          "foreground": "p:fg",
          "background": "p:surface",
          "type": "node",
          "template": "  {{ .Full }} ",
          "options": {
            "display_mode": "files"
          }
        },
        {
          "style": "powerline",
          "powerline_symbol": "",
          "foreground": "p:fg",
          "background": "p:surface",
          "type": "python",
          "template": "  {{ .Full }} ",
          "options": {
            "display_mode": "files"
          }
        },
        {
          "style": "powerline",
          "powerline_symbol": "",
          "foreground": "p:fg",
          "background": "p:surface",
          "type": "go",
          "template": "  {{ .Full }} ",
          "options": {
            "display_mode": "files"
          }
        },
        {
          "style": "powerline",
          "powerline_symbol": "",
          "foreground": "p:fg",
          "background": "p:surface",
          "type": "rust",
          "template": "  {{ .Full }} ",
          "options": {
            "display_mode": "files"
          }
        },
        {
          "style": "powerline",
          "powerline_symbol": "",
          "foreground": "p:fg",
          "background": "p:surface",
          "type": "php",
          "template": "  {{ .Full }} ",
          "options": {
            "display_mode": "files"
          }
        },
        {
          "style": "powerline",
          "powerline_symbol": "",
          "foreground": "p:fg",
          "background": "p:surface",
          "type": "java",
          "template": "  {{ .Full }} ",
          "options": {
            "display_mode": "files"
          }
        },
        {
          "style": "powerline",
          "powerline_symbol": "",
          "foreground": "p:yellow",
          "background": "p:surface",
          "type": "executiontime",
          "template": "  {{ .FormattedMs }} ",
          "options": {
            "threshold": 2000,
            "style": "austin"
          }
        },
        {
          "style": "powerline",
          "powerline_symbol": "",
          "foreground": "p:bg",
          "background": "p:red",
          "type": "status",
          "template": "  {{ .Code }} "
        }
      ]
    },
    {
      "type": "prompt",
      "alignment": "right",
      "overflow": "hide",
      "segments": [
        {
          "type": "battery",
          "style": "plain",
          "foreground": "p:muted",
          "foreground_templates": [
            "{{ if and (eq \"Discharging\" .State.String) (lt .Percentage 20) }}p:red{{ end }}",
            "{{ if eq \"Charging\" .State.String }}p:green{{ end }}"
          ],
          "options": {
            "charging_icon": "󰂄 ",
            "discharging_icon": "󰁾 ",
            "charged_icon": "󰁹 "
          },
          "template": "{{ if not .Error }}{{ .Icon }}{{ .Percentage }}%{{ end }} "
        },
        {
          "type": "time",
          "style": "plain",
          "foreground": "p:muted",
          "template": " {{ .CurrentDate | date .Format }}",
          "options": {
            "time_format": "15:04"
          }
        }
      ]
    },
    {
      "type": "prompt",
      "alignment": "left",
      "newline": true,
      "segments": [
        {
          "type": "text",
          "style": "plain",
          "foreground": "p:fg",
          "foreground_templates": [
            "{{ if gt .Code 0 }}p:red{{ end }}"
          ],
          "template": "❯"
        }
      ]
    }
  ],
  "secondary_prompt": {
    "foreground": "p:muted",
    "template": "❯❯ "
  }
}
