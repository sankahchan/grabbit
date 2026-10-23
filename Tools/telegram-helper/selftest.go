package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"github.com/gotd/td/telegram"
	"github.com/gotd/td/telegram/downloader"
	"github.com/gotd/td/telegram/message"
	"github.com/gotd/td/tg"
)

// runSelfTest uses the user's own Saved Messages to verify upload -> download
// without involving any third-party channel or content.
func runSelfTest(ctx context.Context, client *telegram.Client) error {
	api := client.API()

	dir, err := os.MkdirTemp("", "grabbit-telegram-selftest-")
	if err != nil {
		return fmt.Errorf("create temp directory: %w", err)
	}
	defer os.RemoveAll(dir)

	srcPath := filepath.Join(dir, "grabbit-telegram-test.bin")
	data := make([]byte, 1024)
	for i := range data {
		data[i] = byte((i*37 + 11) % 256)
	}
	if err := os.WriteFile(srcPath, data, 0600); err != nil {
		return fmt.Errorf("write test file: %w", err)
	}
	want := sha256.Sum256(data)
	fmt.Printf("SELF_TEST_SOURCE\t%d\t%s\n", len(data), hex.EncodeToString(want[:]))

	updates, err := message.NewSender(api).
		Self().
		Upload(message.FromPath(srcPath)).
		File(ctx)
	if err != nil {
		return fmt.Errorf("upload test file to Saved Messages: %w", err)
	}

	msg, err := messageFromUpdates(ctx, api, updates)
	if err != nil {
		return err
	}
	doc, err := documentFromMessage(msg)
	if err != nil {
		return err
	}
	fmt.Printf("SELF_TEST_UPLOADED\tmessage=%d\tdocument=%d\tsize=%d\n",
		msg.ID, doc.GetID(), doc.GetSize())

	outPath := filepath.Join(dir, "downloaded.bin")
	if _, err := downloader.NewDownloader().
		WithPartSize(512*1024).
		Download(api, doc.AsInputDocumentFileLocation()).
		WithThreads(4).
		ToPath(ctx, outPath); err != nil {
		return fmt.Errorf("download test file: %w", err)
	}

	got, err := os.ReadFile(outPath)
	if err != nil {
		return fmt.Errorf("read downloaded file: %w", err)
	}
	gotSum := sha256.Sum256(got)
	if gotSum != want {
		return fmt.Errorf("checksum mismatch: got %s, want %s",
			hex.EncodeToString(gotSum[:]), hex.EncodeToString(want[:]))
	}
	fmt.Printf("SELF_TEST_OK\t%d\t%s\n", len(got), hex.EncodeToString(gotSum[:]))

	// Remove the temporary test message so Saved Messages is left clean.
	if _, err := api.MessagesDeleteMessages(ctx, &tg.MessagesDeleteMessagesRequest{
		Revoke: true,
		ID:     []int{msg.ID},
	}); err != nil {
		fmt.Printf("SELF_TEST_CLEANUP_WARNING\t%v\n", err)
	} else {
		fmt.Println("SELF_TEST_CLEANED")
	}

	return nil
}

func messageFromUpdates(ctx context.Context, api *tg.Client, updates tg.UpdatesClass) (*tg.Message, error) {
	var updateList []tg.UpdateClass
	switch u := updates.(type) {
	case *tg.Updates:
		updateList = u.Updates
	case *tg.UpdatesCombined:
		updateList = u.Updates
	case *tg.UpdateShort:
		updateList = []tg.UpdateClass{u.Update}
	case *tg.UpdateShortSentMessage:
		return fetchMessage(ctx, api, u.ID)
	}

	for _, update := range updateList {
		messageUpdate, ok := update.(*tg.UpdateNewMessage)
		if !ok {
			continue
		}
		if msg, ok := messageUpdate.Message.(*tg.Message); ok {
			return msg, nil
		}
	}

	return nil, fmt.Errorf("send succeeded but no message was returned")
}

func fetchMessage(ctx context.Context, api *tg.Client, id int) (*tg.Message, error) {
	result, err := api.MessagesGetMessages(ctx, []tg.InputMessageClass{
		&tg.InputMessageID{ID: id},
	})
	if err != nil {
		return nil, fmt.Errorf("fetch sent message: %w", err)
	}

	var messages []tg.MessageClass
	switch m := result.(type) {
	case *tg.MessagesMessages:
		messages = m.Messages
	case *tg.MessagesMessagesSlice:
		messages = m.Messages
	case *tg.MessagesChannelMessages:
		messages = m.Messages
	}
	for _, raw := range messages {
		if msg, ok := raw.(*tg.Message); ok && msg.ID == id {
			return msg, nil
		}
	}
	return nil, fmt.Errorf("sent message %d was not found", id)
}

func documentFromMessage(msg *tg.Message) (*tg.Document, error) {
	media, ok := msg.Media.(*tg.MessageMediaDocument)
	if !ok {
		return nil, fmt.Errorf("message has no document media (got %T)", msg.Media)
	}
	doc, ok := media.Document.AsNotEmpty()
	if !ok {
		return nil, fmt.Errorf("message has an empty document")
	}
	return doc, nil
}
