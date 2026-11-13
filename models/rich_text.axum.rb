model :RichText, table: :action_text_rich_texts do
  # ActionText::RichText. A message's body is its row named "body" (Message has_one :body_text).

  # has_rich_text :body: the one Action Text row, named body, for the new message. A message created with an attachment
  # and no body (the composer's file post sends none) gets no row, as in Rails, where the row exists only once a body
  # is assigned.
  execute :create_message_body, args: { message_id: :i64, body: :string } do
    insert(record_type: "Message", record_id: arg(:message_id), name: "body", body: arg(:body))
  end
end
