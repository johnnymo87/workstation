local M = {}

-- Helper function to convert HTML to Markdown
local function html_to_markdown(html_content)
  if not html_content or html_content == "" then
    return ""
  end

  local markdown_content = vim.fn.system({"html2markdown"}, html_content)
  if vim.v.shell_error ~= 0 then
    vim.notify(
      "Error converting HTML to Markdown. Shell error: " .. vim.v.shell_error ..
      ". Output: " .. markdown_content,
      vim.log.levels.ERROR
    )
    return "Error converting content to Markdown."
  end

  return markdown_content
end

-- Helper function to format comments with XML-style nesting
local function format_comments(comments, indent_level)
  local indent_level = indent_level or 0
  local indent = string.rep("  ", indent_level)
  local lines = {}

  for _, comment in ipairs(comments) do
    table.insert(lines, indent .. "<comment>")
    table.insert(lines, "")

    -- Author and timestamp
    local author = comment.author and comment.author.displayName or "Unknown"
    local timestamp = comment.created or "Unknown time"
    table.insert(lines, indent .. "  " .. author .. " (" .. timestamp .. ")")

    -- Convert comment body HTML to markdown
    local body_html = ""
    if comment.renderedBody then
      body_html = comment.renderedBody
    elseif comment.body and comment.body.content then
      -- Handle the case where we have structured body content
      -- For now, fallback to a simple representation
      body_html = "Comment body (structured format not fully supported)"
    end

    local body_markdown = html_to_markdown(body_html)
    local body_lines = vim.split(body_markdown, "\n", {plain = true})

    for _, line in ipairs(body_lines) do
      table.insert(lines, indent .. "  " .. line)
    end

    table.insert(lines, "")

    -- Handle replies (if this comment has a parentId, we'll handle nesting in the main function)

    table.insert(lines, indent .. "</comment>")
  end

  return lines
end

-- Helper function to get comment parent information
local function get_comment_parent(comment_id, comment_type, email, api_token)
  local endpoint = comment_type == "ConfluenceInlineComment" and "inline-comments" or "footer-comments"
  local command = string.format(
    "curl --fail --silent --show-error --request GET " ..
    "--url 'https://wonder.atlassian.net/wiki/api/v2/%s/%s' " ..
    "--user '%s:%s' " ..
    "--header 'Accept: application/json' " ..
    "| jq -r '.parentCommentId // \"null\"'",
    endpoint,
    comment_id,
    email,
    api_token
  )

  local output = vim.fn.system(command)
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local parent_id = vim.trim(output)
  return parent_id ~= "null" and parent_id or nil
end

-- Helper function to build comment hierarchy
local function build_comment_hierarchy(comments, email, api_token)
  local comment_map = {}
  local roots = {}

  -- First pass: create comment map and get parent info
  for _, comment in ipairs(comments) do
    comment_map[comment.commentId] = {
      id = comment.commentId,
      type = comment.__typename,
      author = comment.author.user.name,
      body = comment.body.editor.value,
      children = {}
    }
  end

  -- Second pass: build hierarchy
  for _, comment in ipairs(comments) do
    local parent_id = get_comment_parent(comment.commentId, comment.__typename, email, api_token)
    local comment_data = comment_map[comment.commentId]

    if parent_id and comment_map[parent_id] then
      table.insert(comment_map[parent_id].children, comment_data)
    else
      table.insert(roots, comment_data)
    end
  end

  return roots
end

-- Helper function to format confluence comments with hierarchy
local function format_confluence_comments(comments, indent_level)
  local indent_level = indent_level or 0
  local indent = string.rep("  ", indent_level)
  local lines = {}

  for _, comment in ipairs(comments) do
    table.insert(lines, indent .. "<comment>")
    table.insert(lines, "")

    -- Author and comment ID
    table.insert(lines, indent .. "  " .. comment.author .. " (Comment ID: " .. comment.id .. ")")

    -- Convert comment body HTML to markdown
    local body_markdown = html_to_markdown(comment.body)
    local body_lines = vim.split(body_markdown, "\n", {plain = true})

    for _, line in ipairs(body_lines) do
      table.insert(lines, indent .. "  " .. line)
    end

    table.insert(lines, "")

    -- Handle nested replies
    if #comment.children > 0 then
      local child_lines = format_confluence_comments(comment.children, indent_level + 1)
      for _, line in ipairs(child_lines) do
        table.insert(lines, line)
      end
    end

    table.insert(lines, indent .. "</comment>")
  end

  return lines
end

-- Helper function to download attachments for a Jira ticket
local function download_jira_attachments(ticket_key, attachments, email, api_token)
  if not attachments or #attachments == 0 then
    return 0
  end

  -- Create attachments directory
  local home = os.getenv("HOME")
  local attachments_dir = string.format("%s/.cache/atlassian-attachments/jira/%s", home, ticket_key)
  local mkdir_cmd = string.format("mkdir -p %s", vim.fn.shellescape(attachments_dir))
  vim.fn.system(mkdir_cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("Warning: Could not create attachments directory", vim.log.levels.WARN)
    return 0
  end

  -- Download each image attachment
  local download_count = 0
  for _, attachment in ipairs(attachments) do
    local mime_type = attachment.mimeType or ""
    if mime_type:match("^image/") then
      local attachment_id = attachment.id
      local filename = attachment.filename
      local output_path = string.format("%s/%s", attachments_dir, filename)

      local download_cmd = string.format(
        "curl -sS -L --fail " ..
        "--url 'https://wonder.atlassian.net/rest/api/3/attachment/content/%s' " ..
        "--user '%s:%s' " ..
        "--output %s",
        attachment_id,
        email,
        api_token,
        vim.fn.shellescape(output_path)
      )

      vim.fn.system(download_cmd)
      if vim.v.shell_error == 0 then
        download_count = download_count + 1
      else
        vim.notify(
          string.format("Warning: Failed to download %s", filename),
          vim.log.levels.WARN
        )
      end
    end
  end

  return download_count
end

-- Function to fetch Jira ticket content
function M.fetch_jira_ticket(ticket_key)
  if not ticket_key or ticket_key == "" then
    vim.notify("Error: Ticket key is required.", vim.log.levels.ERROR)
    return
  end

  local api_token = os.getenv("ATLASSIAN_API_TOKEN")
  if not api_token or api_token == "" then
    vim.notify("Error: ATLASSIAN_API_TOKEN environment variable is not set.", vim.log.levels.ERROR)
    return
  end

  -- Check dependencies
  if vim.fn.executable("curl") == 0 then
    vim.notify("Error: 'curl' command not found in PATH.", vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable("jq") == 0 then
    vim.notify("Error: 'jq' command not found in PATH.", vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable("html2markdown") == 0 then
    vim.notify("Error: 'html2markdown' command not found in PATH.", vim.log.levels.ERROR)
    return
  end

  local email = os.getenv("ATLASSIAN_EMAIL")
  if not email or email == "" then
    vim.notify("Error: ATLASSIAN_EMAIL environment variable is not set.", vim.log.levels.ERROR)
    return
  end

  -- Fetch ticket data
  local fetch_ticket_command = string.format(
    "curl --fail --silent --show-error --request GET " ..
    "--url 'https://wonder.atlassian.net/rest/api/3/issue/%s?fields=key,summary,description,attachment&expand=renderedFields' " ..
    "--user '%s:%s' " ..
    "--header 'Accept: application/json' " ..
    "| jq '{ \"key\": .key, \"summary\": .fields.summary, \"description\": .renderedFields.description, \"attachments\": .fields.attachment }'",
    ticket_key,
    email,
    api_token
  )

  vim.notify("Fetching Jira ticket data for " .. ticket_key .. "...", vim.log.levels.INFO)

  local ticket_output = vim.fn.system(fetch_ticket_command)
  if vim.v.shell_error ~= 0 then
    vim.notify(
      "Error fetching ticket data from Jira. Shell error: " .. vim.v.shell_error ..
      ". Output: " .. ticket_output,
      vim.log.levels.ERROR
    )
    return
  end

  -- Parse ticket JSON
  local ok, ticket_data = pcall(vim.json.decode, ticket_output)
  if not ok or type(ticket_data) ~= "table" then
    vim.notify("Error: Failed to parse ticket JSON response: " .. (ticket_data or "Invalid JSON"), vim.log.levels.ERROR)
    return
  end

  -- Fetch comments
  local fetch_comments_command = string.format(
    "curl --fail --silent --show-error --request GET " ..
    "--url 'https://wonder.atlassian.net/rest/api/3/issue/%s/comment?expand=renderedBody' " ..
    "--user '%s:%s' " ..
    "--header 'Accept: application/json' " ..
    "| jq '.comments'",
    ticket_key,
    email,
    api_token
  )

  local comments_output = vim.fn.system(fetch_comments_command)
  local comments_data = {}

  if vim.v.shell_error == 0 then
    local comments_ok, parsed_comments = pcall(vim.json.decode, comments_output)
    if comments_ok and type(parsed_comments) == "table" then
      comments_data = parsed_comments
    else
      vim.notify("Warning: Could not parse comments, continuing without them.", vim.log.levels.WARN)
    end
  else
    vim.notify("Warning: Could not fetch comments, continuing without them.", vim.log.levels.WARN)
  end

  -- Download attachments
  local attachment_count = 0
  if ticket_data.attachments and #ticket_data.attachments > 0 then
    vim.notify("Downloading attachments...", vim.log.levels.INFO)
    attachment_count = download_jira_attachments(ticket_key, ticket_data.attachments, email, api_token)
  end

  -- Prepare content
  local lines_to_insert = {}

  -- Title line
  local title = (ticket_data.key or "Unknown") .. " " .. (ticket_data.summary or "No summary")
  table.insert(lines_to_insert, title)
  table.insert(lines_to_insert, "")

  -- Add attachment note if any were downloaded
  if attachment_count > 0 then
    local attachments_path = string.format("~/.cache/atlassian-attachments/jira/%s/", ticket_key)
    table.insert(lines_to_insert, string.format("> **Attachments downloaded to**: `%s`", attachments_path))
    table.insert(lines_to_insert, "")
  end

  -- Description
  if ticket_data.description and ticket_data.description ~= "" then
    local description_markdown = html_to_markdown(ticket_data.description)
    local description_lines = vim.split(description_markdown, "\n", {plain = true})
    for _, line in ipairs(description_lines) do
      table.insert(lines_to_insert, line)
    end
  else
    table.insert(lines_to_insert, "No description available.")
  end

  table.insert(lines_to_insert, "")

  -- Comments section
  if #comments_data > 0 then
    table.insert(lines_to_insert, "<comments>")

    -- Build comment hierarchy (simple approach - just list them in order for now)
    -- TODO: Could enhance this to properly nest replies based on parentId
    local comment_lines = format_comments(comments_data, 1)
    for _, line in ipairs(comment_lines) do
      table.insert(lines_to_insert, line)
    end

    table.insert(lines_to_insert, "</comments>")
  end

  -- Insert into buffer
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  vim.api.nvim_buf_set_lines(bufnr, cursor_row, cursor_row, false, lines_to_insert)

  if attachment_count > 0 then
    vim.notify(
      string.format("Jira ticket content inserted with %d image(s) downloaded.", attachment_count),
      vim.log.levels.INFO
    )
  else
    vim.notify("Jira ticket content inserted.", vim.log.levels.INFO)
  end
end

-- Helper function to download attachments for a page
local function download_attachments(page_id, email, api_token)
  -- Create attachments directory
  local home = os.getenv("HOME")
  local attachments_dir = string.format("%s/.cache/atlassian-attachments/confluence/%s", home, page_id)
  local mkdir_cmd = string.format("mkdir -p %s", vim.fn.shellescape(attachments_dir))
  vim.fn.system(mkdir_cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("Warning: Could not create attachments directory", vim.log.levels.WARN)
    return 0
  end

  -- List attachments
  local list_cmd = string.format(
    "curl --silent --show-error " ..
    "--url 'https://wonder.atlassian.net/wiki/rest/api/content/%s/child/attachment' " ..
    "--user '%s:%s' " ..
    "--header 'Accept: application/json'",
    page_id,
    email,
    api_token
  )

  local attachments_json = vim.fn.system(list_cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify("Warning: Could not list attachments", vim.log.levels.WARN)
    return 0
  end

  -- Parse attachments
  local ok, attachments_data = pcall(vim.json.decode, attachments_json)
  if not ok or type(attachments_data) ~= "table" or not attachments_data.results then
    vim.notify("Warning: Could not parse attachments", vim.log.levels.WARN)
    return 0
  end

  -- Download each PNG attachment
  local download_count = 0
  for _, attachment in ipairs(attachments_data.results) do
    local media_type = attachment.extensions and attachment.extensions.mediaType
    if media_type == "image/png" then
      local attachment_id = attachment.id:gsub("^att", "")
      local filename = attachment.title
      local output_path = string.format("%s/%s", attachments_dir, filename)

      local download_cmd = string.format(
        "curl -sS -L --fail " ..
        "--url 'https://wonder.atlassian.net/wiki/rest/api/content/%s/child/attachment/%s/download' " ..
        "--user '%s:%s' " ..
        "--output %s",
        page_id,
        attachment_id,
        email,
        api_token,
        vim.fn.shellescape(output_path)
      )

      vim.fn.system(download_cmd)
      if vim.v.shell_error == 0 then
        download_count = download_count + 1
      else
        vim.notify(
          string.format("Warning: Failed to download %s", filename),
          vim.log.levels.WARN
        )
      end
    end
  end

  return download_count
end

-- Function to fetch Confluence page content with comments
function M.fetch_page_content(page_id)
  if not page_id or page_id == "" then
    vim.notify("Error: Page ID is required.", vim.log.levels.ERROR)
    return
  end

  local api_token = os.getenv("ATLASSIAN_API_TOKEN")
  if not api_token or api_token == "" then
    vim.notify("Error: ATLASSIAN_API_TOKEN environment variable is not set.", vim.log.levels.ERROR)
    return
  end

  -- Check dependencies
  if vim.fn.executable("curl") == 0 then
    vim.notify("Error: 'curl' command not found in PATH.", vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable("jq") == 0 then
    vim.notify("Error: 'jq' command not found in PATH.", vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable("html2markdown") == 0 then
    vim.notify("Error: 'html2markdown' command not found in PATH.", vim.log.levels.ERROR)
    return
  end

  local email = os.getenv("ATLASSIAN_EMAIL")
  if not email or email == "" then
    vim.notify("Error: ATLASSIAN_EMAIL environment variable is not set.", vim.log.levels.ERROR)
    return
  end

  local cloud_id = os.getenv("ATLASSIAN_CLOUD_ID")
  if not cloud_id or cloud_id == "" then
    vim.notify("Error: ATLASSIAN_CLOUD_ID environment variable is not set.", vim.log.levels.ERROR)
    return
  end

  local page_ari = string.format("ari:cloud:confluence:%s:page/%s", cloud_id, page_id)

  -- GraphQL query
  local graphql_query = [[
query getPageWithComments($id: ID!) {
  confluence {
    page(id: $id) {
      title
      body {
        anonymousExportView {
          value
        }
      }
      comments {
        __typename
        author {
          user {
            name
          }
        }
        body {
          editor {
            value
          }
        }
        commentId
      }
    }
  }
}]]

  -- Prepare GraphQL request
  local graphql_payload = vim.json.encode({
    query = graphql_query,
    variables = { id = page_ari }
  })

  -- Create temporary file for GraphQL payload
  local temp_file = vim.fn.tempname()
  local file = io.open(temp_file, "w")
  if not file then
    vim.notify("Error: Could not create temporary file for GraphQL request.", vim.log.levels.ERROR)
    return
  end
  file:write(graphql_payload)
  file:close()

  -- Execute GraphQL query
  local graphql_command = string.format(
    "curl --fail --silent --show-error --request POST " ..
    "--url 'https://wonder.atlassian.net/gateway/api/graphql' " ..
    "--user '%s:%s' " ..
    "--header 'Accept: application/json' " ..
    "--header 'Content-Type: application/json' " ..
    "--header 'X-ExperimentalApi: confluence-agg-beta' " ..
    "--data @%s",
    email,
    api_token,
    temp_file
  )

  vim.notify("Fetching Confluence page data for " .. page_id .. "...", vim.log.levels.INFO)

  local graphql_output = vim.fn.system(graphql_command)

  -- Clean up temporary file
  os.remove(temp_file)

  -- Check for shell errors
  if vim.v.shell_error ~= 0 then
    vim.notify(
      "Error fetching page data from Confluence GraphQL API. Shell error: " .. vim.v.shell_error ..
      ". Output: " .. graphql_output,
      vim.log.levels.ERROR
    )
    return
  end

  if graphql_output == "" or graphql_output == nil then
    vim.notify("Error: No data received from Confluence GraphQL API.", vim.log.levels.ERROR)
    return
  end

  -- Parse the GraphQL response
  local ok, response = pcall(vim.json.decode, graphql_output)
  if not ok or type(response) ~= "table" then
    vim.notify("Error: Failed to parse GraphQL response: " .. (response or "Invalid JSON"), vim.log.levels.ERROR)
    return
  end

  if response.errors then
    vim.notify("GraphQL errors: " .. vim.json.encode(response.errors), vim.log.levels.ERROR)
    return
  end

  local page_data = response.data and response.data.confluence and response.data.confluence.page
  if not page_data then
    vim.notify("Error: No page data found in GraphQL response.", vim.log.levels.ERROR)
    return
  end

  local title = page_data.title or "Title not found"
  local html_body = page_data.body and page_data.body.anonymousExportView and page_data.body.anonymousExportView.value or ""
  local comments = page_data.comments or {}

  -- Convert HTML body to Markdown
  local markdown_body = html_to_markdown(html_body)
  if markdown_body == "Error converting content to Markdown." then
    markdown_body = "Error converting page body to Markdown."
  end

  -- Download attachments
  vim.notify("Downloading attachments...", vim.log.levels.INFO)
  local attachment_count = download_attachments(page_id, email, api_token)

  -- Prepare lines to insert
  local lines_to_insert = {}
  table.insert(lines_to_insert, title)
  table.insert(lines_to_insert, "") -- Blank line

  -- Add attachment note if any were downloaded
  if attachment_count > 0 then
    local attachments_path = string.format("~/.cache/atlassian-attachments/confluence/%s/", page_id)
    table.insert(lines_to_insert, string.format("> **Attachments downloaded to**: `%s`", attachments_path))
    table.insert(lines_to_insert, "")
  end

  -- Split markdown_body into lines and add them
  for _, line in ipairs(vim.split(markdown_body, "\n", {plain = true})) do
    table.insert(lines_to_insert, line)
  end

  -- Process comments if any exist
  if #comments > 0 then
    vim.notify("Processing " .. #comments .. " comments...", vim.log.levels.INFO)

    -- Build comment hierarchy
    local comment_hierarchy = build_comment_hierarchy(comments, email, api_token)

    -- Separate inline and footer comments
    local inline_comments = {}
    local footer_comments = {}

    for _, comment in ipairs(comment_hierarchy) do
      if comment.type == "ConfluenceInlineComment" then
        table.insert(inline_comments, comment)
      elseif comment.type == "ConfluenceFooterComment" then
        table.insert(footer_comments, comment)
      end
    end

    table.insert(lines_to_insert, "")

    -- Add inline comments section
    if #inline_comments > 0 then
      table.insert(lines_to_insert, "<inline-comments>")
      local inline_comment_lines = format_confluence_comments(inline_comments, 1)
      for _, line in ipairs(inline_comment_lines) do
        table.insert(lines_to_insert, line)
      end
      table.insert(lines_to_insert, "</inline-comments>")
      table.insert(lines_to_insert, "")
    end

    -- Add footer comments section
    if #footer_comments > 0 then
      table.insert(lines_to_insert, "<footer-comments>")
      local footer_comment_lines = format_confluence_comments(footer_comments, 1)
      for _, line in ipairs(footer_comment_lines) do
        table.insert(lines_to_insert, line)
      end
      table.insert(lines_to_insert, "</footer-comments>")
    end
  end

  -- Get current buffer and cursor position
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1

  -- Insert lines at the current cursor position
  vim.api.nvim_buf_set_lines(bufnr, cursor_row, cursor_row, false, lines_to_insert)

  if attachment_count > 0 then
    vim.notify(
      string.format("Confluence page content inserted with %d attachment(s) downloaded.", attachment_count),
      vim.log.levels.INFO
    )
  else
    vim.notify("Confluence page content inserted.", vim.log.levels.INFO)
  end
end

-- Create user commands
vim.api.nvim_create_user_command(
  "FetchConfluencePage",
  function(opts)
    M.fetch_page_content(opts.args)
  end,
  {
    nargs = 1,
    complete = function(arglead, cmdline, cursorpos)
      return {}
    end,
    desc = "Fetch Confluence page by ID and insert its title and content.",
  }
)

vim.api.nvim_create_user_command(
  "FetchJiraTicket",
  function(opts)
    M.fetch_jira_ticket(opts.args)
  end,
  {
    nargs = 1,
    complete = function(arglead, cmdline, cursorpos)
      return {}
    end,
    desc = "Fetch Jira ticket by key and insert its details and comments.",
  }
)

return M
