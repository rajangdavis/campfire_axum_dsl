model :SearchRow, table: :message_search_index do
  # Message::Searchable's FTS5 row (tokenize=porter): the rowid is the message's id, the body its plain text.

  # Message.searchable: the plain text, with the message id as the FTS5 rowid.
  execute :index_message, args: { message_id: :i64, body: :string } do
    insert(rowid: arg(:message_id), body: arg(:body))
  end

  # Message::Searchable#update_in_index: the FTS row's body is the message's plain text.
  execute :reindex_message, args: { message_id: :i64, body: :string } do
    where(rowid: arg(:message_id)).update_all(body: arg(:body))
  end
end
